#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Tests for bin/omamobile-widget: manifest validation, the code checks, the
# qmllint verdict, discovery, new/copy/remove, and the agent launch against
# fake omarchy-* commands. Run by test/all; needs nothing but python3 (the
# qmllint parts skip themselves without it).
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
TOOL = os.path.join(PKG, "bin/omamobile-widget")
TEMPLATE = os.path.join(PKG, "widgets/template")
EXAMPLES = os.path.join(PKG, "widgets/examples")

failed = 0
tests = []


def test(fn):
    tests.append(fn)
    return fn


def load(env):
    """The tool as a module, with its paths from env."""
    old = dict(os.environ)
    os.environ.update(env)
    try:
        loader = importlib.machinery.SourceFileLoader("omamobile_widget", TOOL)
        spec = importlib.util.spec_from_loader("omamobile_widget", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        return mod
    finally:
        os.environ.clear()
        os.environ.update(old)


class Sandbox:
    def __enter__(self):
        self.root = tempfile.mkdtemp(prefix="omamobile-widget-test-")
        self.widgets = os.path.join(self.root, "widgets")
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        self.env = {
            "HOME": self.root,
            "OMAMOBILE_WIDGETS_DIR": self.widgets,
            "OMAMOBILE_WIDGET_TEMPLATE": TEMPLATE,
            "OMAMOBILE_WIDGET_EXAMPLES": EXAMPLES,
            "OMAMOBILE_WIDGET_CONTRACT": os.path.join(PKG, "widgets/WIDGETS.md"),
            "XDG_CACHE_HOME": os.path.join(self.root, "cache"),
            "XDG_DATA_HOME": os.path.join(self.root, "data"),
            "OMAMOBILE_WIDGET_AGENT_WAIT": "1",
            "PATH": self.bin + ":" + os.environ.get("PATH", ""),
            "USER": "tester",
        }
        self.mod = load(self.env)
        return self

    def __exit__(self, *a):
        shutil.rmtree(self.root, ignore_errors=True)

    def run(self, *args):
        env = dict(os.environ)
        env.update(self.env)
        return subprocess.run([sys.executable, TOOL] + list(args), env=env, capture_output=True, text=True, timeout=60)

    def fake(self, name, body):
        path = os.path.join(self.bin, name)
        with open(path, "w") as f:
            f.write("#!/bin/bash\n" + body + "\n")
        os.chmod(path, 0o755)

    def widget(self, wid, manifest=None, qml=None):
        folder = os.path.join(self.widgets, wid)
        shutil.copytree(TEMPLATE, folder)
        with open(os.path.join(folder, "manifest.json")) as f:
            m = json.load(f)
        m["id"] = wid
        if manifest:
            m.update(manifest)
        with open(os.path.join(folder, "manifest.json"), "w") as f:
            json.dump(m, f)
        if qml is not None:
            with open(os.path.join(folder, "Widget.qml"), "w") as f:
                f.write(qml)
        return folder


MOD = load({})


def good(**extra):
    m = {"schemaVersion": 1, "id": "a.b", "name": "B", "version": "1", "kinds": ["home-widget"],
         "entryPoints": {"homeWidget": "Widget.qml"}, "homeWidget": {}}
    m.update(extra)
    return m

# ---------------------------------------------------------------- manifests


@test
def manifest_minimal_gets_defaults():
    spec, errors, warnings = MOD.validate_manifest(good(), "a.b")
    assert errors == [] and warnings == [], (errors, warnings)
    assert spec["size"] == [2, 1] and spec["min"] == [1, 1] and spec["max"] == [6, 8]
    assert spec["capabilities"] == [] and spec["entry"] == "Widget.qml"


@test
def manifest_rejects_what_omarchy_rejects():
    cases = [
        ({"schemaVersion": 2}, "schemaVersion"),
        ({"kinds": ["bar-widget"]}, "home-widget"),
        ({"entryPoints": {"homeWidget": "../x.qml"}}, "inside the widget folder"),
        ({"entryPoints": {"homeWidget": "/etc/x.qml"}}, "inside the widget folder"),
        ({"entryPoints": {"homeWidget": "Widget.js"}}, ".qml"),
        ({"id": "omarchy.clock"}, "reserved"),
        ({"id": "omamobile.x"}, "reserved"),
        ({"id": "omandroid.x"}, "reserved"),
        ({"id": "Bad Id"}, "lower-case"),
        ({"id": "a.c"}, "folder name"),
        ({"name": ""}, "name"),
        ({"homeWidget": []}, "must be an object"),
        ({"homeWidget": {"capabilities": "commands"}}, "capabilities must be a list"),
    ]
    for patch, words in cases:
        spec, errors, _ = MOD.validate_manifest(good(**patch), "a.b")
        assert any(words in e for e in errors), (patch, errors)
    for missing in ("id", "name", "version", "kinds", "entryPoints"):
        m = good()
        del m[missing]
        assert any(missing in e for e in MOD.validate_manifest(m, "a.b")[1]), missing
    assert MOD.validate_manifest([], "a.b")[0] is None


@test
def manifest_sizes_are_clamped():
    spec, errors, warnings = MOD.validate_manifest(good(homeWidget={"size": [9, 0], "min": [2, 2], "max": [3, 99]}), "a.b")
    assert errors == []
    assert spec["min"] == [2, 2] and spec["max"] == [3, 8] and spec["size"] == [3, 2], spec
    assert len(warnings) >= 2
    spec, _, warnings = MOD.validate_manifest(good(homeWidget={"size": "big", "min": [3, 3], "max": [1, 1]}), "a.b")
    assert spec["max"] == [3, 3] and spec["size"] == [3, 3]


@test
def manifest_capabilities_and_schema():
    hw = {"capabilities": ["commands", "network", "commands", "camera"],
          "defaults": {"n": "nope"},
          "schema": [{"key": "n", "type": "integer", "min": 1, "defaultValue": 5},
                     {"key": "mode", "type": "enum", "options": ["a", {"value": "b"}]},
                     {"key": "bad key", "type": "string"}, {"key": "x", "type": "color"},
                     {"key": "n", "type": "string"}, "junk"]}
    spec, errors, warnings = MOD.validate_manifest(good(homeWidget=hw), "a.b")
    assert errors == []
    assert spec["capabilities"] == ["commands", "network"]
    assert any("camera" in w for w in warnings)
    assert [f["key"] for f in spec["schema"]] == ["n", "mode"]
    assert spec["defaults"] == {"n": 5, "mode": "a"}, spec["defaults"]

# ---------------------------------------------------------------- the code


@test
def code_capabilities_are_detected():
    cases = {
        'Process { command: ["ls"] }': ["commands"],
        'Quickshell.execDetached(["foot"])': ["commands"],
        'host.run(["df"], f)': ["commands"],
        'var x = new XMLHttpRequest()': ["network"],
        'Image { source: "https://example.org/a.png" }': ["network"],
        'host.run(["curl", url], f)': ["commands", "network"],
        '// Process { } and https://x in a comment\n/* XMLHttpRequest */ Text { text: "a // b" }': [],
    }
    for src, caps in cases.items():
        detected, errors, _ = MOD.code_checks([("W.qml", src)])
        assert sorted(detected) == sorted(caps), (src, detected)
        assert errors == [], (src, errors)


@test
def code_forbidden_things_are_errors():
    for src in ['host.run(["sudo", "ls"], f)', 'command: ["sh", "-c", "pkexec x"]', 'Process { command: ["run0", "x"] }',
                'import "../../other"', 'import "/usr/share/x"', 'import "https://evil/x"',
                'Qt.createQmlObject("Item{}", w)', 'Qt.createComponent("file:///tmp/x.qml")',
                'Loader { source: "https://x/y.qml" }', 'Loader { source: "/tmp/y.qml" }']:
        assert MOD.code_checks([("W.qml", src)])[1], src
    # Words in text are not commands.
    assert MOD.code_checks([("W.qml", 'Text { text: "Never use sudo here" }')])[1] == []
    assert MOD.code_checks([("W.qml", 'import "Logic.js" as Logic\nLoader { source: "Part.qml" }')])[1] == []


@test
def code_slow_things_are_warnings():
    for src in ["layer.enabled: true", "MultiEffect { }", "Timer { interval: 100 }", "loops: Animation.Infinite"]:
        assert MOD.code_checks([("W.qml", src)])[2], src
    assert MOD.code_checks([("W.qml", "Timer { interval: 60000 }")])[2] == []


@test
def lint_verdict_splits_errors_from_noise():
    report = {"files": [{"filename": "/w/Widget.qml", "warnings": [
        {"id": "syntax", "type": "warning", "line": 5, "message": "Expected token `}'"},
        {"id": "import", "type": "warning", "line": 3, "message": "Rectangel was not found. Did you add all imports and dependencies?"},
        {"id": "missing-property", "type": "warning", "line": 4, "message": 'Could not find property "colr".'},
        {"id": "import", "type": "warning", "line": 1, "message": "Failed to import qs.Nope. Are your import paths set up properly?"},
        {"id": "missing-property", "type": "warning", "line": 9, "message": 'Member "body" not found on type "QObject"'},
        {"id": "unqualified", "type": "warning", "line": 7, "message": "Unqualified access"},
        {"id": "unused-imports", "type": "info", "line": 2, "message": "Unused import"}]}]}
    errors, warnings = MOD.lint_verdict(report)
    assert [e.split(":")[1] for e in errors] == ["5", "3", "4", "1"], errors
    assert warnings == ["Widget.qml:7: Unqualified access"], warnings
    assert MOD.lint_verdict({}) == ([], [])

# ---------------------------------------------------------------- folders


@test
def scan_reports_each_folder():
    with Sandbox() as s:
        os.makedirs(s.widgets)
        s.widget("t.ok")
        s.widget("t.nofile", {"entryPoints": {"homeWidget": "Missing.qml"}})
        s.widget("t.caps", qml=open(os.path.join(TEMPLATE, "Widget.qml")).read().replace(
            "Item {\n  id: widget", 'Item {\n  id: widget\n  Component.onCompleted: host.run(["date"], function(r) {})'))
        bad = os.path.join(s.widgets, "t.json")
        os.makedirs(bad)
        open(os.path.join(bad, "manifest.json"), "w").write("{")
        os.makedirs(os.path.join(s.widgets, ".hidden-staging"))
        open(os.path.join(s.widgets, "README"), "w").write("not a widget")
        outside = os.path.join(s.root, "outside")
        shutil.copytree(TEMPLATE, outside)
        os.symlink(outside, os.path.join(s.widgets, "t.link"))
        leak = s.widget("t.leak")
        os.symlink("/etc/hostname", os.path.join(leak, "data.txt"))

        out = s.run("scan")
        assert out.returncode == 0, out.stderr
        data = json.loads(out.stdout)
        by = {w["id"]: w for w in data["widgets"]}
        assert sorted(by) == ["t.caps", "t.json", "t.leak", "t.link", "t.nofile", "t.ok"], sorted(by)
        assert by["t.ok"]["status"] == "ok", by["t.ok"]
        assert by["t.ok"]["hash"] and by["t.ok"]["manifest"]["name"] == "My widget"
        assert any("Missing.qml is missing" in e for e in by["t.nofile"]["errors"])
        assert by["t.caps"]["undeclared"] == ["commands"] and by["t.caps"]["status"] == "error"
        assert any("not valid JSON" in e for e in by["t.json"]["errors"])
        assert any("outside" in e for e in by["t.link"]["errors"])
        assert any("links outside" in e for e in by["t.leak"]["errors"])
        assert [e["id"] for e in data["examples"]] == ["countdown", "disk-space"]
        assert all(e["status"] == "ok" for e in data["examples"]), data["examples"]
        # The contract is linked from the widgets folder.
        assert os.path.islink(os.path.join(s.widgets, "WIDGETS.md"))


@test
def scan_hash_follows_content():
    with Sandbox() as s:
        f = s.widget("t.ok")
        h1 = s.mod.inspect(f, s.widgets, "user", lint=False)["hash"]
        open(os.path.join(f, "Widget.qml"), "a").write("\n// changed\n")
        h2 = s.mod.inspect(f, s.widgets, "user", lint=False)["hash"]
        open(os.path.join(f, ".swap"), "w").write("editor junk")
        h3 = s.mod.inspect(f, s.widgets, "user", lint=False)["hash"]
        assert h1 != h2 and h2 == h3


@test
def too_big_widgets_are_refused():
    with Sandbox() as s:
        f = s.widget("t.big")
        open(os.path.join(f, "blob.bin"), "wb").write(b"\0" * (1 << 20))
        assert any("too big" in e for e in s.mod.inspect(f, s.widgets, "user", lint=False)["errors"])


@test
def new_copy_remove():
    with Sandbox() as s:
        out = s.run("new", "tester.moon", "Moon phase; $(echo no)")
        assert out.returncode == 0, out.stderr
        m = json.load(open(os.path.join(s.widgets, "tester.moon", "manifest.json")))
        assert m["id"] == "tester.moon" and m["name"] == "Moon phase; $(echo no)" and m["author"] == "tester"
        assert s.run("new", "tester.moon", "Again").returncode == 3
        assert s.run("new", "../escape", "x").returncode == 2
        assert s.run("new", "omarchy.clock", "x").returncode == 2
        assert s.run("copy-example", "countdown").returncode == 0
        assert os.path.isfile(os.path.join(s.widgets, "countdown", "Widget.qml"))
        assert s.run("copy-example", "../../etc").returncode == 2
        assert s.run("copy-example", "nope").returncode == 2
        # Nothing half-made is left behind.
        assert sorted(os.listdir(s.widgets)) == ["WIDGETS.md", "countdown", "tester.moon"], os.listdir(s.widgets)
        out = s.run("remove", "tester.moon")
        assert out.returncode == 0, out.stderr
        assert not os.path.exists(os.path.join(s.widgets, "tester.moon"))
        moved = out.stdout.strip()
        assert moved.startswith(os.path.join(s.root, "data/omamobile/removed-widgets/tester.moon-")) and os.path.isdir(moved)
        assert s.run("remove", "tester.moon").returncode == 3

# ---------------------------------------------------------------- the agent


AGENT_FAKES = {
    # Omarchy's own: prints the chosen agent, or nothing.
    "omarchy-default-agent": '[[ -f "$HOME/agent" ]] && cat "$HOME/agent"; exit 0',
    "omarchy-agent": 'echo "omarchy-agent $*" >> "$HOME/calls"',
    # One app per screen: the terminal maps on an empty workspace.
    "omamobile-launch": 'echo "omamobile-launch $*" >> "$HOME/calls"',
    "omarchy-agent-prompt": '''{ echo "cwd=$PWD"; echo "argc=$#"; printf '%s' "$1" > "$HOME/prompt"; } >> "$HOME/calls"
case $(cat "$HOME/agent") in
  missing) echo "missing is not installed. Choose an installed agent with: omarchy default agent <name>" >&2; exit 1 ;;
  quick) exit 0 ;;
esac
sleep 3''',
}


def agent_sandbox(s, agent):
    for name, body in AGENT_FAKES.items():
        s.fake(name, body)
    if agent is not None:
        open(os.path.join(s.root, "agent"), "w").write(agent + "\n")
    s.run("new", "tester.moon", "Moon")


def calls(s):
    try:
        return open(os.path.join(s.root, "calls")).read()
    except OSError:
        return ""


NASTY = 'moon; $(touch "$HOME/pwned") `id` "q" \'s\' & | > x\nline two -- --inline'


@test
def agent_unset_opens_omarchys_chooser():
    with Sandbox() as s:
        agent_sandbox(s, None)
        out = s.run("agent", "tester.moon", NASTY)
        assert out.returncode == 3, (out.returncode, out.stderr)
        assert "No coding agent is chosen" in out.stderr
        for _ in range(50):
            if "--pick" in calls(s):
                break
            subprocess.run(["sleep", "0.05"])
        assert "omarchy-agent --pick" in calls(s), calls(s)
        assert "argc=" not in calls(s)


@test
def agent_missing_is_reported():
    with Sandbox() as s:
        agent_sandbox(s, "missing")
        out = s.run("agent", "tester.moon", "x")
        assert out.returncode == 4, (out.returncode, out.stderr)
        assert "missing is not installed" in out.stderr


@test
def agent_gets_the_prompt_as_one_argument_in_the_folder():
    for agent in ("claude", "quick"):
        with Sandbox() as s:
            agent_sandbox(s, agent)
            out = s.run("agent", "tester.moon", NASTY)
            assert out.returncode == 0, (agent, out.returncode, out.stderr)
            log = calls(s)
            assert "cwd=" + os.path.join(s.widgets, "tester.moon") in log, log
            assert "argc=1" in log, log
            assert log.index("omamobile-launch empty") < log.index("argc=1"), log
            assert open(os.path.join(s.root, "prompt")).read() == NASTY
            assert not os.path.exists(os.path.join(s.root, "pwned"))


@test
def agent_refuses_bad_ids_and_empty_prompts():
    with Sandbox() as s:
        agent_sandbox(s, "claude")
        assert s.run("agent", "../x", "p").returncode == 2
        assert s.run("agent", "tester.nope", "p").returncode == 2
        assert s.run("agent", "tester.moon", "  ").returncode == 2
        assert "argc=" not in calls(s)

# ---------------------------------------------------------------- qmllint


@test
def shipped_widgets_pass_the_check():
    if not MOD.qmllint_path() or not os.path.isdir(os.path.join(MOD.OMARCHY_PATH, "shell")):
        print("ok - widget tool: shipped widgets pass qmllint # SKIP no qmllint or Omarchy shell")
        return
    with Sandbox() as s:
        for folder in [TEMPLATE] + [os.path.join(EXAMPLES, n) for n in sorted(os.listdir(EXAMPLES))]:
            r = s.mod.inspect(folder, os.path.dirname(folder), "check")
            assert r["status"] == "ok" and r["lint"]["ran"], (folder, r["errors"], r["lint"])
            assert r["warnings"] == [], (folder, r["warnings"])
        broken = s.widget("t.syntax", qml="import QtQuick\nItem {\n  Rectangel { }\n")
        r = s.mod.inspect(broken, s.widgets, "user")
        assert r["status"] == "error" and r["lint"]["errors"], r
        out = s.run("check", broken)
        assert out.returncode == 1 and "not ok" in out.stdout, out.stdout


for fn in tests:
    try:
        fn()
        print("ok - widget tool: " + fn.__name__.replace("_", " "))
    except Exception as e:  # noqa: BLE001
        failed += 1
        import traceback
        print("not ok - widget tool: " + fn.__name__.replace("_", " ") + "\n  " + traceback.format_exc().replace("\n", "\n  "))
sys.exit(1 if failed else 0)
