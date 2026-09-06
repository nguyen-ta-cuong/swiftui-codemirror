import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { CompletionContext } from "@codemirror/autocomplete";
import { EditorState } from "@codemirror/state";
import {
  applyChanges,
  documentDiagnostics,
  EditorController,
  formatJSON,
  isAnalysisAvailable,
  jsonLiteralCompletion,
  validateChanges
} from "../codemirror.js";

function makeController(initialText = "") {
  const messages = [];
  const handlers = new Map();
  const controller = new EditorController(message => messages.push(message), { body: null });
  controller.sessionID = "session";
  controller.replicaID = "replica";
  controller.loadID = "load";
  let state = EditorState.create({ doc: initialText });
  const dom = {
    addEventListener(name, handler) { handlers.set(name, handler); },
    removeEventListener(name) { handlers.delete(name); },
    setAttribute() {},
    style: { setProperty() {} }
  };
  controller.view = {
    get state() { return state; },
    set state(value) { state = value; },
    dom,
    dispatch(spec) {
      if (!spec.changes && !spec.selection && !spec.effects) {
        return;
      }
      const startState = state;
      const transaction = state.update(spec);
      state = transaction.state;
      controller.handleUpdate({
        docChanged: transaction.docChanged,
        selectionSet: transaction.selectionSet,
        startState,
        state,
        changes: transaction.changes
      });
    },
    destroy() {}
  };
  return { controller, handlers, messages, get text() { return state.doc.toString(); } };
}

function applyLocalChange(controller, spec) {
  const startState = controller.view.state;
  const transaction = startState.update(spec);
  controller.view.state = transaction.state;
  controller.handleUpdate({
    docChanged: transaction.docChanged,
    selectionSet: transaction.selectionSet,
    startState,
    state: transaction.state,
    changes: transaction.changes
  });
}

function waitForEventLoop() {
  return new Promise(resolve => setTimeout(resolve, 0));
}

test("validates UTF-16 changes without splitting surrogate pairs", () => {
  assert.deepEqual(validateChanges("😀x", [{ fromUTF16: 2, toUTF16: 2, insertedText: "!" }]), { valid: true, reason: null });
  assert.deepEqual(validateChanges("😀x", [{ fromUTF16: 1, toUTF16: 1, insertedText: "!" }]), { valid: false, reason: "surrogate" });
  assert.deepEqual(validateChanges("abc", [
    { fromUTF16: 2, toUTF16: 2, insertedText: "x" },
    { fromUTF16: 1, toUTF16: 1, insertedText: "y" }
  ]), { valid: false, reason: "order" });
});

test("applies sorted deltas in reverse order", () => {
  const source = "012345";
  const result = applyChanges(source, [
    { fromUTF16: 1, toUTF16: 2, insertedText: "a" },
    { fromUTF16: 4, toUTF16: 5, insertedText: "b" }
  ]);
  assert.equal(result, "0a23b5");
});

test("formats JSON lexically without changing key order, duplicates, numbers, or escapes", () => {
  const source = '{"first":1e+03,"first":"\\u0041","items":[true,false]}';
  const result = formatJSON(source);
  assert.equal(result.available, true);
  assert.equal(result.text, [
    "{",
    "  \"first\": 1e+03,",
    "  \"first\": \"\\u0041\",",
    "  \"items\": [",
    "    true,",
    "    false",
    "  ]",
    "}"
  ].join("\n"));
});

test("invalid JSON remains unchanged with an advisory diagnostic", () => {
  const source = '{"unfinished":';
  const result = formatJSON(source);
  assert.equal(result.available, false);
  assert.equal(result.text, source);
  assert.match(result.diagnostic, /invalid|incomplete/i);
});

test("large documents stay editable while analysis is unavailable", () => {
  const source = "x".repeat(1024 * 1024 + 1);
  assert.equal(isAnalysisAvailable(source), false);
  assert.equal(applyChanges(source, [{ fromUTF16: 0, toUTF16: 0, insertedText: "{" }]).length, source.length + 1);
});

test("bundled language modes expose advisory JSON, XML, and GraphQL diagnostics", () => {
  const jsonDiagnostics = documentDiagnostics("json", '{"enabled":');
  const xmlDiagnostics = documentDiagnostics("xml", "<root><item></root>");
  const graphqlDiagnostics = documentDiagnostics("graphql", "query { viewer ");
  assert.equal(jsonDiagnostics[0].source, "JSON");
  assert.equal(xmlDiagnostics[0].source, "XML");
  assert.equal(graphqlDiagnostics[0].source, "GraphQL");
  assert.equal(documentDiagnostics("json", '{"enabled":true}').length, 0);
  assert.equal(documentDiagnostics("xml", "<root><item /></root>").length, 0);
  assert.equal(documentDiagnostics("graphql", "query { viewer }").length, 0);
});

test("the editor controller publishes diagnostics into selectable visible state", () => {
  const harness = makeController('{"enabled":');
  const { controller } = harness;
  controller.configured = true;
  controller.initializing = false;
  controller.configuration = { ...controller.configuration, language: "json" };
  const panel = {
    textContent: "",
    hidden: true,
    classList: { toggle() {} },
    remove() {}
  };
  controller.diagnosticsPanel = panel;
  controller.refreshDiagnostics();
  assert.equal(panel.hidden, false);
  assert.match(panel.textContent, /JSON|invalid|incomplete/i);
  controller.destroy();
});

test("large language documents expose selectable unavailable state without truncating source", () => {
  const source = "{" + "x".repeat(1024 * 1024) + "}";
  const diagnostics = documentDiagnostics("json", source);
  assert.equal(diagnostics.length, 1);
  assert.equal(diagnostics[0].severity, "info");
  assert.match(diagnostics[0].message, /unavailable|fully editable/i);
  assert.equal(applyChanges(source, [{ fromUTF16: source.length, toUTF16: source.length, insertedText: " " }]).length, source.length + 1);

  const harness = makeController(source);
  harness.controller.configured = true;
  harness.controller.initializing = false;
  harness.controller.configuration = { ...harness.controller.configuration, language: "json" };
  harness.controller.format("large-format");
  assert.deepEqual(harness.messages.at(-1), {
    type: "formatResult",
    requestID: "large-format",
    success: false,
    sessionID: "session",
    replicaID: "replica",
    loadID: "load"
  });
  harness.controller.destroy();
});

test("JSON literal completion remains available through the CodeMirror completion source", () => {
  const state = EditorState.create({ doc: "tru", selection: { anchor: 3 } });
  const result = jsonLiteralCompletion(new CompletionContext(state, 3, false));
  assert.ok(result);
  assert.deepEqual(result.options.map(option => option.label), ["true", "false", "null"]);
});

test("the packaged page is local-only and exposes the built host transport", async () => {
  const html = await readFile(new URL("../../Sources/CodeMirror/web.bundle/index.html", import.meta.url), "utf8");
  const bundle = await readFile(new URL("../../Sources/CodeMirror/web.bundle/codemirror.bundle.js", import.meta.url), "utf8");
  assert.match(html, /default-src 'none'/);
  assert.match(html, /script-src 'self'/);
  assert.match(html, /<script src="\.\/bootstrap\.js"><\/script>/);
  assert.doesNotMatch(html, /<script>\s*CodeMirrorHost\.start/);
  assert.match(html, /cm-host-diagnostics/);
  assert.match(html, /user-select: text/);
  assert.match(html, /display: flex; flex-direction: column/);
  assert.match(html, /\.cm-editor \{ order: 1; flex: 1 1 auto; min-height: 0;/);
  assert.match(html, /\.cm-host-diagnostics \{\s*order: 2;/);
  assert.doesNotMatch(html, /\.cm-host-diagnostics \{[^}]*position: absolute/s);
  assert.match(html, /color-scheme: light dark/);
  assert.match(html, /cm-host-reduce-transparency/);
  assert.match(bundle, /CodeMirrorHost/);
  assert.match(bundle, /cm-host-diagnostics/);
  assert.match(bundle, /fully editable/);
  assert.match(bundle, /focusTraversal/);
  assert.match(bundle, /Ctrl-Tab/);
});

test("runtime notices retain installed permission text and classify non-bundled locks", async () => {
  const notices = await readFile(
    new URL("../../Sources/CodeMirror/web.bundle/THIRD-PARTY-NOTICES.md", import.meta.url),
    "utf8"
  );
  assert.match(notices, /Bundled runtime package count: [1-9]\d*/);
  assert.match(notices, /### @codemirror\/state@/);
  assert.match(notices, /### graphql@/);
  assert.match(notices, /Copyright/);
  assert.match(notices, /Permission is hereby granted/);
  assert.match(notices, /not-bundled/);
  assert.doesNotMatch(notices, /89 package notice compliance/);
});

test("post messages carry the active native identity after configuration", () => {
  const messages = [];
  const controller = new EditorController(message => messages.push(message), { body: null });
  controller.sessionID = "session";
  controller.replicaID = "replica";
  controller.loadID = "load";
  controller.post({ type: "selection", revision: 4, selection: { anchorUTF16: 0, headUTF16: 0 } });
  controller.post({ type: "ready" });
  assert.deepEqual(messages, [
    {
      type: "selection",
      revision: 4,
      selection: { anchorUTF16: 0, headUTF16: 0 },
      sessionID: "session",
      replicaID: "replica",
      loadID: "load"
    },
    { type: "ready" }
  ]);
});

test("Ctrl-Tab traversal requests native focus movement in both directions", () => {
  const harness = makeController("");
  harness.controller.configured = true;
  harness.controller.initializing = false;
  harness.controller.sendFocusTraversal(true);
  harness.controller.sendFocusTraversal(false);
  assert.deepEqual(harness.messages.slice(-2).map(message => [message.type, message.direction]), [
    ["focusTraversal", "next"],
    ["focusTraversal", "previous"]
  ]);
  harness.controller.destroy();
});

test("compositionend waits for the final CodeMirror update before flushing", async () => {
  const { controller, handlers, messages } = makeController("");
  controller.configured = true;
  controller.initializing = false;
  controller.installCompositionHandlers();
  handlers.get("compositionstart")();
  controller.flush("flush");
  handlers.get("compositionend")();
  assert.equal(messages.some(message => message.type === "flushResult"), false);

  applyLocalChange(controller, { changes: { from: 0, insert: "a" } });
  assert.equal(messages.some(message => message.type === "flushResult"), false);
  controller.acknowledge(1);
  assert.deepEqual(messages.at(-1), { type: "flushResult", requestID: "flush", success: true, sessionID: "session", replicaID: "replica", loadID: "load" });
  controller.destroy();
});

test("compositionend without a changed document settles on the next event-loop turn", async () => {
  const { controller, handlers, messages } = makeController("");
  controller.configured = true;
  controller.initializing = false;
  controller.installCompositionHandlers();
  handlers.get("compositionstart")();
  controller.flush("empty-composition");
  handlers.get("compositionend")();
  assert.equal(messages.some(message => message.type === "flushResult"), false);
  await waitForEventLoop();
  assert.deepEqual(messages.at(-1), {
    type: "flushResult",
    requestID: "empty-composition",
    success: true,
    sessionID: "session",
    replicaID: "replica",
    loadID: "load"
  });
  controller.destroy();
});

test("initial configuration replaces only the disabled loading document and never emits a full local overwrite", () => {
  const harness = makeController("");
  const { controller, messages } = harness;
  assert.equal(controller.initializing, true);
  applyLocalChange(controller, { changes: { from: 0, insert: "typed before configure" } });
  assert.equal(controller.localEditBeforeConfiguration, true);
  controller.configure({
    sessionID: "session",
    replicaID: "replica",
    loadID: "load",
    revision: 7,
    text: "authoritative initial source",
    selections: [],
    configuration: controller.configuration
  });
  assert.equal(harness.text, "authoritative initial source");
  assert.equal(messages.some(message => message.type === "transaction"), false);
  assert.equal(controller.initializing, false);
  assert.equal(messages.at(-1).type, "configured");
  controller.destroy();
});

test("divergent replicas fail flush while retaining recovery state", () => {
  const harness = makeController("local text");
  const { controller, messages } = harness;
  controller.configured = true;
  controller.initializing = false;
  controller.divergent = true;
  controller.flush("divergent");
  assert.deepEqual(messages.at(-1), {
    type: "flushResult",
    requestID: "divergent",
    success: false,
    code: "conflictingEdit",
    sessionID: "session",
    replicaID: "replica",
    loadID: "load"
  });
  assert.equal(controller.divergent, true);
  assert.equal(harness.text, "local text");
  controller.destroy();
});

test("programmatic apply preserves input that arrives after an acknowledged flush", () => {
  const harness = makeController("one");
  const { controller, messages } = harness;
  controller.configured = true;
  controller.initializing = false;
  controller.hostText = "one";
  controller.hostRevision = 0;
  controller.localRevision = 0;

  applyLocalChange(controller, { changes: { from: 3, insert: "!" } });
  controller.flush("before-undo");
  controller.acknowledge(1);
  assert.deepEqual(messages.at(-1), {
    type: "flushResult",
    requestID: "before-undo",
    success: true,
    sessionID: "session",
    replicaID: "replica",
    loadID: "load"
  });

  applyLocalChange(controller, { changes: { from: 4, insert: "?" } });
  controller.receive({ type: "apply", revision: 1, text: "one", selections: [] });
  assert.equal(harness.text, "one!?");
  assert.equal(controller.divergent, true);
  controller.flush("after-undo");
  assert.deepEqual(messages.at(-1), {
    type: "flushResult",
    requestID: "after-undo",
    success: false,
    code: "conflictingEdit",
    sessionID: "session",
    replicaID: "replica",
    loadID: "load"
  });
  controller.destroy();
});
