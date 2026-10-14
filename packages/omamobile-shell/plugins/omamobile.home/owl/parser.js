.pragma library
.import "lexer.js" as Lexer
// SPDX-License-Identifier: MIT
// The OWL parser: tokens to a syntax tree. A hand-written recursive descent
// over the grammar in the language guide. Pure JS, no QML.
//
// Expressions are { e: kind, at, ... }:
//   lit {v}  name {name}  text {parts}  list {items}  map {keys, values}
//   unary {op, x}  binary {op, l, r}  cond {test, yes, no}
//   member {obj, name}  index {obj, key}  call {name, args, named}
//   lambda {params, body}
// A body (the widget's, a node's, a block's) is
//   { props, handlers, anims, items, decls }
// with items { item: "node" | "if" | "for" | "let" | "draw", ... } and
// declarations { decl: "source" | "state" | "let" | "asset" | "component" |
// "meta" | "requires" | "trigger", ... }.

var CompileError = Lexer.CompileError

var BLOCK_DECLS = ["meta", "requires"]
var DECLS = ["source", "state", "let", "asset", "component", "meta", "requires"]
var TRIGGERS = ["every", "at", "when", "on"]
// Lowest first. The conditional ?: sits below all of them.
var PRECEDENCE = [["??"], ["||"], ["&&"], ["==", "!="], ["<", "<=", ">", ">="], ["+", "-"], ["*", "/", "%"]]

function Parser(src, tokens) {
  this.src = src
  this.tokens = tokens
  this.i = 0
}

Parser.prototype = {
  cur: function() { return this.tokens[this.i] },
  ahead: function(n) { return this.tokens[Math.min(this.i + (n || 1), this.tokens.length - 1)] },
  take: function() { return this.tokens[this.i++] },
  isOp: function(t, text) { return t.kind === "op" && t.text === text },
  isWord: function(t, text) { return t.kind === "name" && t.text === text },

  describe: function(t) {
    if (t.kind === "end") return "end of file"
    if (t.kind === "string") return "string"
    return "'" + t.text + "'"
  },
  error: function(message, token) { throw new CompileError(message, (token || this.cur()).at) },
  need: function(text) {
    if (!this.isOp(this.cur(), text)) this.error("expected '" + text + "', found " + this.describe(this.cur()))
    return this.take()
  },
  skip: function(text) {
    if (!this.isOp(this.cur(), text)) return false
    this.i++
    return true
  },
  name: function(what) {
    var t = this.cur()
    if (t.kind !== "name") this.error("expected " + (what || "a name") + ", found " + this.describe(t))
    this.i++
    return t.text
  },
  // A trailing word that only counts on the same line (persist, json, ...).
  sameLineWord: function(word) {
    var t = this.cur()
    if (t.kind === "name" && t.text === word && !t.nl) { this.i++; return true }
    return false
  },

  // ---------------------------------------------------------------- file

  file: function() {
    if (!this.isWord(this.cur(), "widget")) this.error("a widget file starts with: widget \"name\" {")
    this.take()
    var name = this.cur().kind === "string" ? this.plainString(this.take()) : null
    this.need("{")
    var body = this.body(true)
    this.need("}")
    if (this.cur().kind !== "end") this.error("expected end of file, found " + this.describe(this.cur()))
    return { name: name, body: body }
  },

  plainString: function(t) {
    if (t.parts.length === 1 && t.parts[0].text !== undefined) return t.parts[0].text
    this.error("expected a plain string", t)
  },

  // ---------------------------------------------------------------- bodies

  body: function(top) {
    var b = { props: [], handlers: [], anims: [], items: [], decls: [] }
    while (!this.isOp(this.cur(), "}") && this.cur().kind !== "end") {
      if (this.skip(";")) continue
      var first = this.cur()
      if (first.kind !== "name") this.error("expected a property, node or declaration, found " + this.describe(first))
      var word = first.text
      var next = this.ahead()
      if (TRIGGERS.indexOf(word) >= 0 && !this.isOp(next, ":") && !this.isOp(next, "{")) {
        if (!top) this.error("'" + word + "' is only allowed at the top of the widget")
        this.take()
        var expr = this.expr()
        if (!this.isOp(this.cur(), "{")) this.error("expected '{' with the statements to run: " + word + " ... { ... }")
        b.decls.push({ decl: "trigger", trigger: word, expr: expr, stmts: this.statements(), at: first.at })
      } else if (word === "if") {
        b.items.push(this.ifItem())
      } else if (word === "for") {
        b.items.push(this.forItem())
      } else if (word === "animate" && next.kind === "name") {
        this.take()
        var prop = this.name("property to animate")
        this.need(":")
        b.anims.push({ name: prop, value: this.expr(), at: first.at })
      } else if (word === "let" && !top && next.kind === "name") {
        this.take()
        var letName = this.name()
        this.need("=")
        b.items.push({ item: "let", name: letName, value: this.expr(), at: first.at })
      } else if (DECLS.indexOf(word) >= 0 && (next.kind === "name" || (BLOCK_DECLS.indexOf(word) >= 0 && this.isOp(next, "{")))) {
        if (!top) this.error("'" + word + "' is only allowed at the top of the widget")
        b.decls.push(this.declaration())
      } else if (this.isOp(next, ":")) {
        this.take()
        this.take()
        if (/^on[A-Z]/.test(word)) b.handlers.push({ name: word, stmts: this.statements(), at: first.at })
        else b.props.push({ name: word, value: this.expr(), at: first.at })
      } else if (this.isOp(next, "{")) {
        this.take()
        this.take()
        var inner = this.body(false)
        this.need("}")
        b.items.push({ item: "node", type: word, body: inner, at: first.at })
      } else {
        if (!this.isOp(next, "(") || next.nl) this.error("expected ':' or '{' after '" + word + "'", next)
        var call = this.primary()
        if (call.e !== "call") this.error("expected a call", first)
        var block = null
        if (this.isOp(this.cur(), "{") && !this.cur().nl) {
          this.take()
          block = this.body(false)
          this.need("}")
        }
        b.items.push({ item: "draw", call: call, body: block, at: first.at })
      }
    }
    return b
  },

  ifItem: function() {
    var at = this.take().at
    var cond = this.expr()
    this.need("{")
    var yes = this.body(false)
    this.need("}")
    var no = null
    if (this.isWord(this.cur(), "else")) {
      this.take()
      if (this.isWord(this.cur(), "if")) {
        no = { props: [], handlers: [], anims: [], items: [this.ifItem()], decls: [] }
      } else {
        this.need("{")
        no = this.body(false)
        this.need("}")
      }
    }
    return { item: "if", cond: cond, then: yes, otherwise: no, at: at }
  },

  forItem: function() {
    var at = this.take().at
    var name = this.name("loop variable")
    var index = this.skip(",") ? this.name("index variable") : null
    if (!this.isWord(this.cur(), "in")) this.error("expected 'in'")
    this.take()
    var list = this.expr()
    var key = null
    if (this.isWord(this.cur(), "key")) {
      this.take()
      key = this.expr()
    }
    this.need("{")
    var body = this.body(false)
    this.need("}")
    return { item: "for", name: name, index: index, list: list, key: key, body: body, at: at }
  },

  declaration: function() {
    var keyword = this.take()
    var kind = keyword.text
    if (BLOCK_DECLS.indexOf(kind) >= 0) {
      this.need("{")
      var fields = []
      while (!this.isOp(this.cur(), "}")) {
        if (this.skip(";") || this.skip(",")) continue
        var at = this.cur().at
        var field = this.name(kind + " field")
        this.need(":")
        fields.push({ name: field, value: this.expr(), at: at })
      }
      this.need("}")
      return { decl: kind, fields: fields, at: keyword.at }
    }
    var name = this.name()
    if (kind === "component") {
      if (!/^[A-Z]/.test(name)) this.error("component names start with a capital letter", keyword)
      var params = []
      if (this.skip("(")) {
        while (!this.isOp(this.cur(), ")")) {
          var param = this.name("parameter")
          params.push({ name: param, fallback: this.skip("=") ? this.expr() : null })
          if (!this.skip(",")) break
        }
        this.need(")")
      }
      this.need("{")
      var body = this.body(false)
      this.need("}")
      return { decl: "component", name: name, params: params, body: body, at: keyword.at }
    }
    this.need("=")
    if (kind === "let") {
      var value = this.expr()
      return { decl: "let", name: name, value: value, persist: this.sameLineWord("persist"), at: keyword.at }
    }
    if (kind === "state") {
      var init = this.expr()
      return { decl: "state", name: name, init: init, persist: this.sameLineWord("persist"), at: keyword.at }
    }
    if (kind === "asset") {
      if (!this.isWord(this.cur(), "base64")) this.error("expected base64\"...\"")
      this.take()
      if (this.cur().kind !== "string") this.error("expected string, found " + this.describe(this.cur()))
      return { decl: "asset", name: name, base64: this.plainString(this.take()).replace(/\s/g, ""), at: keyword.at }
    }
    var source = { decl: "source", name: name, expr: this.expr(), every: null, json: false, timeout: null,
                   status: false, optional: false, at: keyword.at }
    // Modifiers, in any order, on the same line.
    while (this.cur().kind === "name" && !this.cur().nl) {
      var w = this.cur().text
      if (w === "every") { this.take(); source.every = this.unary() }
      else if (w === "timeout") { this.take(); source.timeout = this.unary() }
      else if (w === "json") { this.take(); source.json = true }
      else if (w === "status") { this.take(); source.status = true }
      else if (w === "optional") { this.take(); source.optional = true }
      else break
    }
    return source
  },

  // A handler's statements: one, or a { } block of them.
  statements: function() {
    if (!this.isOp(this.cur(), "{")) return [this.statement()]
    this.take()
    var list = []
    while (!this.isOp(this.cur(), "}")) {
      if (this.skip(";")) continue
      list.push(this.statement())
    }
    this.need("}")
    return list
  },

  statement: function() {
    var first = this.cur()
    if (first.kind === "name" && this.isOp(this.ahead(), "=")) {
      this.take()
      this.take()
      return { stmt: "assign", name: first.text, value: this.expr(), at: first.at }
    }
    var e = this.expr()
    if (e.e !== "call") this.error("expected an assignment (x = ...) or an action like run(\"...\")", first)
    return { stmt: "do", call: e, at: first.at }
  },

  // ---------------------------------------------------------------- expressions

  expr: function() {
    var test = this.binary(0)
    if (!this.isOp(this.cur(), "?")) return test
    var q = this.take()
    var yes = this.expr()
    this.need(":")
    return { e: "cond", test: test, yes: yes, no: this.expr(), at: q.at }
  },

  binary: function(level) {
    if (level === PRECEDENCE.length) return this.unary()
    var left = this.binary(level + 1)
    while (this.cur().kind === "op" && PRECEDENCE[level].indexOf(this.cur().text) >= 0) {
      var op = this.take()
      left = { e: "binary", op: op.text, l: left, r: this.binary(level + 1), at: op.at }
    }
    return left
  },

  unary: function() {
    if (this.isOp(this.cur(), "!") || this.isOp(this.cur(), "-")) {
      var op = this.take()
      return { e: "unary", op: op.text, x: this.unary(), at: op.at }
    }
    return this.postfix(this.primary())
  },

  postfix: function(target) {
    var e = target
    for (;;) {
      if (this.isOp(this.cur(), ".")) {
        this.take()
        var at = this.cur().at
        var field = this.cur().kind === "number" ? this.take().text : this.name("field name")
        if (this.isOp(this.cur(), "(") && !this.cur().nl) {
          // A method is a function: x.map(f) is map(x, f).
          var a = this.callArgs()
          e = { e: "call", name: field, args: [e].concat(a.args), named: a.named, at: at }
        } else {
          e = { e: "member", obj: e, name: field, at: at }
        }
      } else if (this.isOp(this.cur(), "[") && !this.cur().nl) {
        var open = this.take()
        var key = this.expr()
        this.need("]")
        e = { e: "index", obj: e, key: key, at: open.at }
      } else {
        return e
      }
    }
  },

  callArgs: function() {
    this.need("(")
    var args = [], named = []
    while (!this.isOp(this.cur(), ")")) {
      if (this.cur().kind === "name" && this.isOp(this.ahead(), ":")) {
        var n = this.take().text
        this.take()
        named.push({ name: n, value: this.expr() })
      } else {
        if (named.length) this.error("positional arguments go before named ones")
        args.push(this.expr())
      }
      if (!this.skip(",")) break
    }
    this.need(")")
    return { args: args, named: named }
  },

  lambdaAhead: function() {
    if (this.cur().kind === "name") return this.isOp(this.ahead(), "=>")
    if (!this.isOp(this.cur(), "(")) return false
    for (var n = 1; ; n++) {
      var t = this.ahead(n)
      if (this.isOp(t, ")")) return this.isOp(this.ahead(n + 1), "=>")
      if (t.kind !== "name" && !this.isOp(t, ",")) return false
    }
  },

  primary: function() {
    var t = this.cur()
    if (this.lambdaAhead()) {
      var params = []
      if (this.skip("(")) {
        while (!this.isOp(this.cur(), ")")) {
          params.push(this.name("parameter"))
          if (!this.skip(",")) break
        }
        this.need(")")
      } else {
        params.push(this.name())
      }
      this.need("=>")
      return { e: "lambda", params: params, body: this.expr(), at: t.at }
    }
    switch (t.kind) {
    case "name":
      this.take()
      if (t.text === "null") return { e: "lit", v: null, at: t.at }
      if (t.text === "true") return { e: "lit", v: true, at: t.at }
      if (t.text === "false") return { e: "lit", v: false, at: t.at }
      if (this.isOp(this.cur(), "(") && !this.cur().nl) {
        var a = this.callArgs()
        return { e: "call", name: t.text, args: a.args, named: a.named, at: t.at }
      }
      return { e: "name", name: t.text, at: t.at }
    case "string":
      this.take()
      return this.stringExpr(t)
    case "number":
      this.take()
      if (t.size) return { e: "lit", v: [t.size[0], t.size[1]], at: t.at }
      return { e: "lit", v: t.value, at: t.at }
    case "color":
      this.take()
      return { e: "color", hex: t.text, at: t.at }
    case "op":
      if (t.text === "(") {
        this.take()
        var inner = this.expr()
        this.need(")")
        return inner
      }
      if (t.text === "[") {
        this.take()
        var items = []
        while (!this.isOp(this.cur(), "]")) {
          items.push(this.expr())
          if (!this.skip(",")) break
        }
        this.need("]")
        return { e: "list", items: items, at: t.at }
      }
      if (t.text === "{") {
        this.take()
        var keys = [], values = []
        while (!this.isOp(this.cur(), "}")) {
          if (this.cur().kind === "name") keys.push(this.take().text)
          else if (this.cur().kind === "string") keys.push(this.plainString(this.take()))
          else this.error("expected a key")
          this.need(":")
          values.push(this.expr())
          if (!this.skip(",")) this.skip(";")
        }
        this.need("}")
        return { e: "map", keys: keys, values: values, at: t.at }
      }
    }
    if (t.kind === "end") this.error("expected a value, found end of file")
    this.error("expected a value, found " + this.describe(t))
  },

  // "a ${b} c": literal pieces and expressions parsed from their own ranges.
  stringExpr: function(t) {
    if (t.parts.length === 1 && t.parts[0].text !== undefined) return { e: "lit", v: t.parts[0].text, at: t.at }
    var self = this
    var parts = t.parts.map(function(part) {
      if (part.text !== undefined) return { e: "lit", v: part.text, at: t.at }
      var sub = new Parser(self.src, Lexer.tokenize(self.src, part.code[0], part.code[1]))
      var e = sub.expr()
      if (sub.cur().kind !== "end") sub.error("expected end of file, found " + sub.describe(sub.cur()))
      return e
    })
    return { e: "text", parts: parts, at: t.at }
  }
}

function parse(src) {
  return new Parser(src, Lexer.tokenize(src)).file()
}

if (typeof module !== "undefined") {
  module.exports = { parse: parse, CompileError: CompileError }
}
