.pragma library
// SPDX-License-Identifier: MIT
// The OWL lexer: source text to tokens. Pure JS, no QML.
//
// A token is { kind, text, at, nl, value, size, parts }:
//   kind   "name", "number", "color", "string", "op" or "end"
//   at     offset of its first character (errors point there)
//   nl     whether a line break came before it (properties end at one)
//   value  a number's value (durations already in seconds)
//   size   [w, h] for a size literal such as 3x2
//   parts  a string's pieces: { text } literal, or { code: [from, to] }, the
//          source range of a ${...} to parse as an expression

function CompileError(message, at) {
  this.message = message
  this.at = at
}
CompileError.prototype.toString = function() { return this.message }

var PAIRS = ["==", "!=", "<=", ">=", "&&", "||", "??", "=>"]
var SINGLES = "{}()[],;:.?=<>+-*/%!"
// Durations are seconds; dp, px and deg are only labels.
var UNITS = { "": 1, s: 1, ms: 0.001, m: 60, min: 60, h: 3600, dp: 1, px: 1, deg: 1 }

function isDigit(c) { return c >= "0" && c <= "9" }
function isLetter(c) {
  return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c > "\u007f" && c.toLowerCase() !== c.toUpperCase())
}
function isWordChar(c) { return isLetter(c) || isDigit(c) || c === "_" }
function isBlank(c) {
  return c === " " || c === "\t" || c === "\n" || c === "\r" || c === "\f" || c === "\u000b" || c === " "
}

// """ strings lose the indentation their lines share, and a first and last
// line that hold only whitespace.
function dedent(body) {
  var lines = body.split("\n")
  if (lines.length && lines[0].trim() === "") lines.shift()
  if (lines.length && lines[lines.length - 1].trim() === "") lines.pop()
  var common = -1
  lines.forEach(function(line) {
    if (line.trim() === "") return
    var n = 0
    while (n < line.length && isBlank(line.charAt(n))) n++
    common = common < 0 ? n : Math.min(common, n)
  })
  if (common < 0) common = 0
  return lines.map(function(line) { return line.trim() === "" ? "" : line.slice(common) }).join("\n")
}

// Tokens of src[from, to). Interpolations are lexed again later from their
// own range, so positions always refer to the whole file.
function tokenize(src, from, to) {
  var pos = from === undefined ? 0 : from
  var end = to === undefined ? src.length : to
  var tokens = []
  var lineBreak = false

  function ch(i) { return i < end ? src.charAt(i) : "" }
  function push(kind, start, extra) {
    var t = { kind: kind, text: src.slice(start, pos), at: start, nl: lineBreak, value: 0, size: null, parts: null }
    if (extra) for (var k in extra) t[k] = extra[k]
    tokens.push(t)
    lineBreak = false
  }

  function skipBlanks() {
    while (pos < end) {
      var c = src.charAt(pos)
      if (c === "\n") { lineBreak = true; pos++ }
      else if (isBlank(c)) pos++
      else if (c === "/" && ch(pos + 1) === "/") { while (pos < end && src.charAt(pos) !== "\n") pos++ }
      else if (c === "/" && ch(pos + 1) === "*") {
        var close = src.indexOf("*/", pos + 2)
        if (close < 0 || close >= end) throw new CompileError("unterminated comment", pos)
        if (src.slice(pos, close).indexOf("\n") >= 0) lineBreak = true
        pos = close + 2
      } else return
    }
  }

  function digitRun() {
    var start = pos
    while (pos < end && (isDigit(src.charAt(pos)) || src.charAt(pos) === "_")) pos++
    if (ch(pos) === "." && isDigit(ch(pos + 1))) {
      pos++
      while (pos < end && isDigit(src.charAt(pos))) pos++
    }
    return parseFloat(src.slice(start, pos).replace(/_/g, ""))
  }

  function number() {
    var start = pos
    if (src.charAt(pos) === "0" && ch(pos + 1) === "x") {
      pos += 2
      var hexStart = pos
      while (pos < end && (isLetter(src.charAt(pos)) || isDigit(src.charAt(pos)))) pos++
      var hex = src.slice(hexStart, pos)
      if (!/^[0-9a-fA-F]+$/.test(hex)) throw new CompileError("bad hex number", start)
      push("number", start, { value: parseInt(hex, 16) })
      return
    }
    var v = digitRun()
    if (ch(pos) === "x" && isDigit(ch(pos + 1))) {
      pos++
      var h = digitRun()
      push("number", start, { value: v, size: [v, h] })
      return
    }
    var unitStart = pos
    while (pos < end && isLetter(src.charAt(pos))) pos++
    var unit = src.slice(unitStart, pos)
    if (!UNITS.hasOwnProperty(unit)) throw new CompileError("unknown unit '" + unit + "'", unitStart)
    push("number", start, { value: unit === "ms" ? v / 1000 : v * UNITS[unit] })
  }

  function escaped() {
    if (pos + 1 >= src.length) throw new CompileError("unterminated string", pos)
    var e = src.charAt(pos + 1)
    pos += 2
    switch (e) {
    case "0": return "\u0000"
    case "e": return "\u001b"
    case "n": return "\n"
    case "r": return "\r"
    case "t": return "\t"
    default: return e
    }
  }

  // The } that closes an interpolation opened just before `from`.
  function closingBrace(from) {
    var depth = 0
    for (var j = from; j < end; j++) {
      var c = src.charAt(j)
      if (c === "\n") throw new CompileError("unterminated ${", from - 2)
      if (c === "\"" || c === "'") {
        for (j++; j < end && src.charAt(j) !== c; j++) if (src.charAt(j) === "\\") j++
      } else if (c === "{") depth++
      else if (c === "}") {
        if (depth === 0) return j
        depth--
      }
    }
    throw new CompileError("unterminated ${", from - 2)
  }

  function doubleQuoted() {
    var start = pos
    var parts = []
    var buffer = ""
    pos++
    while (pos < end && src.charAt(pos) !== "\n") {
      var c = src.charAt(pos)
      if (c === "\"") {
        pos++
        if (buffer.length || !parts.length) parts.push({ text: buffer })
        push("string", start, { parts: parts })
        return
      }
      if (c === "\\") { buffer += escaped(); continue }
      if (c === "$" && ch(pos + 1) === "{") {
        if (buffer.length) { parts.push({ text: buffer }); buffer = "" }
        var codeFrom = pos + 2
        pos = closingBrace(codeFrom)
        parts.push({ code: [codeFrom, pos] })
        pos++
        continue
      }
      buffer += c
      pos++
    }
    throw new CompileError("unterminated string", start)
  }

  function singleQuoted() {
    var start = pos
    var buffer = ""
    pos++
    while (pos < end) {
      var c = src.charAt(pos)
      if (c === "'") {
        pos++
        push("string", start, { parts: [{ text: buffer }] })
        return
      }
      if (c === "\\" && (ch(pos + 1) === "'" || ch(pos + 1) === "\\")) {
        buffer += src.charAt(pos + 1)
        pos += 2
        continue
      }
      buffer += c
      pos++
    }
    throw new CompileError("unterminated string", start)
  }

  function tripleQuoted() {
    var start = pos
    var close = src.indexOf("\"\"\"", pos + 3)
    if (close < 0 || close >= end) throw new CompileError("unterminated \"\"\" string", start)
    var body = dedent(src.slice(pos + 3, close))
    if (body.charAt(0) === "\n") body = body.slice(1)
    pos = close + 3
    push("string", start, { parts: [{ text: body }] })
  }

  for (;;) {
    skipBlanks()
    if (pos >= end) {
      tokens.push({ kind: "end", text: "", at: end, nl: true, value: 0, size: null, parts: null })
      return tokens
    }
    var start = pos
    var c = src.charAt(pos)
    if (isLetter(c) || c === "_") {
      while (pos < end && isWordChar(src.charAt(pos))) pos++
      push("name", start)
    } else if (isDigit(c)) {
      number()
    } else if (c === "#") {
      pos++
      while (pos < end && (isLetter(src.charAt(pos)) || isDigit(src.charAt(pos)))) pos++
      var literal = src.slice(start, pos)
      if (!/^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(literal))
        throw new CompileError("bad color '" + literal + "'", start)
      push("color", start)
    } else if (c === "\"" && ch(pos + 1) === "\"" && ch(pos + 2) === "\"") {
      tripleQuoted()
    } else if (c === "\"") {
      doubleQuoted()
    } else if (c === "'") {
      singleQuoted()
    } else {
      var two = pos + 1 < end ? src.substr(pos, 2) : ""
      if (PAIRS.indexOf(two) >= 0) pos += 2
      else if (SINGLES.indexOf(c) >= 0) pos += 1
      else throw new CompileError("unexpected character '" + c + "'", pos)
      push("op", start)
    }
  }
}

if (typeof module !== "undefined") {
  module.exports = { tokenize: tokenize, CompileError: CompileError, dedent: dedent }
}
