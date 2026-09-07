import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { runInNewContext } from "node:vm";
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

function makeController(initialText = "", Controller = EditorController) {
  const messages = [];
  const handlers = new Map();
  const documentHandlers = new Map();
  const findInputNotifications = [];
  const findInput = {
    value: "",
    selectionStart: 0,
    selectionEnd: 0,
    selectionDirection: "forward",
    setSelectionRange(start, end, direction = "forward") {
      this.selectionStart = start;
      this.selectionEnd = end;
      this.selectionDirection = direction;
    },
    dispatchEvent(event) {
      documentHandlers.get(event.type)?.({ target: this, isTrusted: false });
      findInputNotifications.push({ type: event.type, value: this.value });
      return true;
    }
  };
  const documentRef = {
    body: null,
    activeElement: null,
    querySelector(selector) {
      return selector === ".cm-search input" ? findInput : null;
    },
    addEventListener(name, handler) { documentHandlers.set(name, handler); },
    removeEventListener(name) { documentHandlers.delete(name); }
  };
  const controller = new Controller(message => messages.push(message), documentRef);
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
    contentDOM: {},
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
  return {
    controller,
    documentHandlers,
    documentRef,
    findInput,
    findInputNotifications,
    handlers,
    messages,
    get text() { return state.doc.toString(); }
  };
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

function dispatchFindInput(harness, nextValue, inputType = "insertText", selectionStart = nextValue.length) {
  const { controller, documentHandlers, documentRef, findInput } = harness;
  documentRef.activeElement = findInput;
  documentHandlers.get("beforeinput")({
    target: findInput,
    inputType,
    isTrusted: true,
    preventDefault() {},
    stopImmediatePropagation() {}
  });
  findInput.value = nextValue;
  findInput.setSelectionRange(selectionStart, selectionStart);
  documentHandlers.get("input")({ target: findInput, inputType, isTrusted: true });
  return controller.findHistory;
}

function focusFindInput(harness) {
  const { documentHandlers, documentRef, findInput } = harness;
  documentRef.activeElement = findInput;
  documentHandlers.get("focusin")({ target: findInput });
}

function makeFindController(t, Controller = EditorController) {
  const harness = makeController("document source", Controller);
  harness.controller.configured = true;
  harness.controller.initializing = false;
  harness.controller.installFocusHandlers();
  harness.controller.installCommandContextHandlers();
  focusFindInput(harness);
  t.after(() => harness.controller.destroy());
  return harness;
}

function beginFindInput(harness, overrides = {}) {
  const event = {
    target: harness.findInput,
    inputType: "insertText",
    isTrusted: true,
    defaultPrevented: false,
    preventDefault() { this.defaultPrevented = true; },
    ...overrides
  };
  harness.documentHandlers.get("beforeinput")(event);
  return event;
}

function assertFindHistoryBudget(controller) {
  const history = controller.findHistory;
  const snapshots = new Set([
    history.current, ...history.undo, ...history.redo,
    history.pendingBeforeInput?.before, history.compositionStart
  ].filter(Boolean));
  const units = [...snapshots].reduce((total, snapshot) => total + snapshot.value.length, 0);
  assert.ok(units <= 1024 * 1024, `retained ${units} UTF-16 units`);
  assert.equal(controller.findHistoryUnits(history), units);
  assert.ok(history.undo.length + history.redo.length <= 32);
}

test("Find beforeinput synchronizes an immediate selection change without losing Undo", t => {
  const harness = makeFindController(t);
  const { controller, findInput } = harness;
  dispatchFindInput(harness, "abcd");
  findInput.setSelectionRange(1, 3, "backward");
  dispatchFindInput(harness, "aXd", "insertText", 2);
  assert.equal(controller.performFindHistory("undo", findInput, controller.findContextID), true);
  assert.equal(findInput.value, "abcd");
  assert.deepEqual([findInput.selectionStart, findInput.selectionEnd, findInput.selectionDirection], [1, 3, "backward"]);
  assert.equal(controller.performFindHistory("redo", findInput, controller.findContextID), true);
  assert.equal(findInput.value, "aXd");
});

test("Find canceled beforeinput expires and cannot pair with a later trusted input", async t => {
  const harness = makeFindController(t);
  const { controller, findInput, documentHandlers } = harness;
  dispatchFindInput(harness, "a");
  beginFindInput(harness).preventDefault();
  await Promise.resolve();
  assert.notEqual(controller.findHistory.pendingBeforeInput, null);
  await waitForEventLoop();
  assert.equal(controller.findHistory.pendingBeforeInput, null);
  findInput.value = "late";
  documentHandlers.get("input")({ target: findInput, inputType: "insertText", isTrusted: true });
  assert.equal(controller.findHistory.current.value, "late");
  assert.equal(controller.findHistory.undo.length, 0);
  assert.equal(controller.findHistory.redo.length, 0);
  beginFindInput(harness, { defaultPrevented: true });
  assert.equal(controller.findHistory.pendingBeforeInput, null);
});

test("Find canceled beforeinput reports a reconciled programmatic baseline", async t => {
  const harness = makeFindController(t);
  const { controller, findInput, messages } = harness;
  dispatchFindInput(harness, "a");
  await Promise.resolve();
  const previousContextID = controller.findContextID;
  messages.length = 0;
  findInput.value = "external";
  beginFindInput(harness).preventDefault();
  await waitForEventLoop();
  assert.notEqual(controller.findContextID, previousContextID);
  assert.equal(controller.findHistory.pendingBeforeInput, null);
  assert.equal(controller.findHistory.undo.length, 0);
  assert.equal(messages.at(-1)?.type, "commandContext");
  assert.equal(messages.at(-1)?.findContextID, controller.findContextID);
  assert.equal(messages.at(-1)?.undoEnabled, false);
});

test("Find untrusted and mismatched input retire pending transactions to a live baseline", t => {
  const harness = makeFindController(t);
  const { controller, findInput, documentHandlers } = harness;
  dispatchFindInput(harness, "a");
  beginFindInput(harness);
  beginFindInput(harness, { isTrusted: false });
  assert.equal(controller.findHistory.pendingBeforeInput, null);
  beginFindInput(harness);
  findInput.value = "untrusted";
  documentHandlers.get("input")({ target: findInput, inputType: "insertText", isTrusted: false });
  assert.equal(controller.findHistory.current.value, "untrusted");
  assert.equal(controller.findHistory.undo.length, 0);
  beginFindInput(harness);
  findInput.value = "mismatched";
  documentHandlers.get("input")({ target: findInput, inputType: "deleteContentBackward", isTrusted: true });
  assert.equal(controller.findHistory.current.value, "mismatched");
  assert.equal(controller.findHistory.undo.length, 0);
});

test("Find trusted input remains paired after the actual WebKit microtask boundary", async t => {
  const harness = makeFindController(t);
  const { controller, documentHandlers, findInput } = harness;
  beginFindInput(harness);
  const pending = controller.findHistory.pendingBeforeInput;
  await Promise.resolve();
  assert.equal(controller.findHistory.pendingBeforeInput, pending);
  findInput.value = "q";
  findInput.setSelectionRange(1, 1);
  documentHandlers.get("input")({ target: findInput, inputType: "insertText", isTrusted: true });
  assert.equal(controller.findBeforeInputExpiryTimer, null);
  assert.equal(controller.findHistory.pendingBeforeInput, null);
  assert.equal(controller.findCommandAvailability("undo").isEnabled, true);
  assert.equal(controller.performFindHistory("undo", findInput, controller.findContextID), true);
  assert.equal(findInput.value, "");
  await waitForEventLoop();
  assert.equal(controller.findHistory.redo.length, 1);
});

test("Find pending task expiry rejects stale context, generation, and timer identities", t => {
  const callbacks = new Map();
  const active = new Set();
  t.mock.method(globalThis, "setTimeout", (callback, delay) => {
    assert.equal(delay, 0);
    const timer = {};
    callbacks.set(timer, callback);
    active.add(timer);
    return timer;
  });
  t.mock.method(globalThis, "clearTimeout", timer => active.delete(timer));
  const harness = makeFindController(t);
  const { controller, documentHandlers, findInput } = harness;
  beginFindInput(harness);
  const first = controller.findHistory.pendingBeforeInput;
  const firstTimer = controller.findBeforeInputExpiryTimer;
  assert.equal(active.size, 1);
  beginFindInput(harness);
  const second = controller.findHistory.pendingBeforeInput;
  const secondTimer = controller.findBeforeInputExpiryTimer;
  assert.notEqual(second.generation, first.generation);
  assert.equal(active.size, 1);
  assert.equal(active.has(firstTimer), false);
  callbacks.get(firstTimer)();
  assert.equal(controller.findHistory.pendingBeforeInput, second);
  assert.equal(controller.findBeforeInputExpiryTimer, secondTimer);
  const oldContext = controller.findContextID;
  documentHandlers.get("focusout")({ target: findInput });
  assert.equal(active.size, 0);
  focusFindInput(harness);
  beginFindInput(harness);
  const replacement = controller.findHistory.pendingBeforeInput;
  const replacementTimer = controller.findBeforeInputExpiryTimer;
  assert.notEqual(controller.findContextID, oldContext);
  callbacks.get(secondTimer)();
  assert.equal(controller.findHistory.pendingBeforeInput, replacement);
  assert.equal(controller.findBeforeInputExpiryTimer, replacementTimer);
  callbacks.get(replacementTimer)();
  active.delete(replacementTimer);
  assert.equal(controller.findHistory.pendingBeforeInput, null);
  assert.equal(controller.findBeforeInputExpiryTimer, null);
  dispatchFindInput(harness, "q");
  assert.equal(active.size, 0);
  beginFindInput(harness);
  const retiredTimer = controller.findBeforeInputExpiryTimer;
  controller.resetFindHistory(findInput, controller.findSnapshot(findInput));
  assert.equal(active.size, 0);
  callbacks.get(retiredTimer)();
  assert.equal(controller.findHistory.pendingBeforeInput, null);
  beginFindInput(harness);
  const destroyedTimer = controller.findBeforeInputExpiryTimer;
  controller.destroy();
  assert.equal(active.size, 0);
  callbacks.get(destroyedTimer)();
  assert.equal(controller.findHistory, null);
  assert.equal(controller.findBeforeInputExpiryTimer, null);
});

test("Find budgets include uniquely retained pending and composition snapshots", async t => {
  const harness = makeFindController(t);
  const { controller, documentHandlers, findInput } = harness;
  dispatchFindInput(harness, "a".repeat(400000));
  dispatchFindInput(harness, "b".repeat(400000));
  beginFindInput(harness);
  assert.equal(controller.findHistory.pendingBeforeInput.before, controller.findHistory.current);
  assertFindHistoryBudget(controller);
  documentHandlers.get("compositionstart")({ target: findInput });
  assert.equal(controller.findHistory.compositionStart, controller.findHistory.current);
  assertFindHistoryBudget(controller);
  dispatchFindInput(harness, "c".repeat(400000), "insertCompositionText");
  assertFindHistoryBudget(controller);
  assert.equal(controller.findHistory.undo.length, 0);
  assert.equal(controller.findHistory.compositionStart.value[0], "b");
  dispatchFindInput(harness, "d".repeat(700000), "insertCompositionText");
  assertFindHistoryBudget(controller);
  assert.equal(controller.findHistory.compositionStart, null);
  assert.equal(controller.findCommandAvailability("undo").isEnabled, false);
  documentHandlers.get("compositionend")({ target: findInput });
  await waitForEventLoop();
  assert.equal(controller.findHistory.current.value, findInput.value);
  assert.equal(controller.findHistory.undo.length, 0);
  assert.equal(controller.findHistory.redo.length, 0);
  assertFindHistoryBudget(controller);
});

test("Find discards a pending transaction when live selection retention cannot fit", t => {
  const harness = makeFindController(t);
  const { controller, documentHandlers, findInput } = harness;
  dispatchFindInput(harness, "a".repeat(700000));
  beginFindInput(harness);
  findInput.setSelectionRange(0, 1, "backward");
  documentHandlers.get("selectionchange")();
  assert.equal(controller.findHistory.pendingBeforeInput, null);
  assertFindHistoryBudget(controller);
  findInput.value = "fresh";
  documentHandlers.get("input")({ target: findInput, inputType: "insertText", isTrusted: true });
  assert.equal(controller.findHistory.current.value, "fresh");
  assert.equal(controller.findHistory.undo.length, 0);
  assert.equal(controller.findHistory.redo.length, 0);
});

test("Find oversized composition values are not retained and settle to a fresh bounded baseline", async t => {
  const harness = makeFindController(t);
  const { controller, findInput, documentHandlers } = harness;
  dispatchFindInput(harness, "a");
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, "x".repeat(1024 * 1024 + 1), "insertCompositionText");
  assert.equal(controller.findHistory.current, null);
  assert.equal(controller.findHistory.compositionStart, null);
  assertFindHistoryBudget(controller);
  dispatchFindInput(harness, "bounded", "insertCompositionText");
  assert.equal(controller.findCommandAvailability("undo").isEnabled, false);
  documentHandlers.get("compositionend")({ target: findInput });
  await waitForEventLoop();
  assert.equal(controller.findHistory.current.value, "bounded");
  assert.equal(controller.findHistory.undo.length, 0);
  dispatchFindInput(harness, "bounded!");
  assert.equal(controller.performFindHistory("undo", findInput, controller.findContextID), true);
  assert.equal(findInput.value, "bounded");
  assertFindHistoryBudget(controller);
});

test("Find composition cancellation notifies Search with restored value and selection", async t => {
  const harness = makeFindController(t);
  const { controller, findInput, documentHandlers, findInputNotifications } = harness;
  dispatchFindInput(harness, "ab");
  findInput.setSelectionRange(0, 1, "backward");
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, "中b", "insertCompositionText", 1);
  documentHandlers.get("compositioncancel")({ target: findInput });
  await waitForEventLoop();
  assert.deepEqual(findInputNotifications, [{ type: "input", value: "ab" }]);
  assert.deepEqual([findInput.selectionStart, findInput.selectionEnd, findInput.selectionDirection], [0, 1, "backward"]);
  assert.equal(controller.findHistory.current.value, "ab");
  assert.equal(harness.text, "document source");
  assert.equal(harness.messages.filter(message => message.type === "command").length, 0);
});

test("Find failed local application resets stacks and availability to observed live state", t => {
  const harness = makeFindController(t);
  const { controller, findInput } = harness;
  dispatchFindInput(harness, "ab");
  dispatchFindInput(harness, "abc");
  const dispatch = findInput.dispatchEvent.bind(findInput);
  findInput.dispatchEvent = event => {
    const result = dispatch(event);
    findInput.value = "interrupted";
    findInput.setSelectionRange(2, 2);
    return result;
  };
  assert.equal(controller.performFindHistory("undo", findInput, controller.findContextID), false);
  assert.equal(controller.findHistory.current.value, "interrupted");
  assert.equal(controller.findHistory.current.selectionStart, 2);
  assert.equal(controller.findHistory.undo.length, 0);
  assert.equal(controller.findHistory.redo.length, 0);
  assert.equal(controller.findCommandAvailability("undo").isEnabled, false);
  assert.equal(controller.findCommandAvailability("redo").isEnabled, false);
});

test("Find failed cancellation selection restores only the observed baseline", async t => {
  const harness = makeFindController(t);
  const { controller, findInput, documentHandlers, findInputNotifications } = harness;
  dispatchFindInput(harness, "ab");
  findInput.setSelectionRange(0, 1, "backward");
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, "中b", "insertCompositionText", 1);
  findInput.setSelectionRange = () => {};
  documentHandlers.get("compositioncancel")({ target: findInput });
  await waitForEventLoop();
  assert.equal(controller.findHistory.undo.length, 0);
  assert.equal(controller.findHistory.redo.length, 0);
  assert.deepEqual(controller.findHistory.current, controller.findSnapshot(findInput));
  assert.deepEqual(findInputNotifications, [{ type: "input", value: "ab" }]);
});

test("Find retired composition settlement cannot settle a replacement focus epoch", async t => {
  const harness = makeFindController(t);
  const { controller, findInput, documentHandlers } = harness;
  dispatchFindInput(harness, "a");
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, "old", "insertCompositionText");
  documentHandlers.get("compositioncancel")({ target: findInput });
  documentHandlers.get("focusout")({ target: findInput });
  focusFindInput(harness);
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, "new", "insertCompositionText");
  await waitForEventLoop();
  assert.equal(findInput.value, "new");
  assert.equal(controller.findHistory.compositionActive, true);
  documentHandlers.get("compositionend")({ target: findInput });
  await waitForEventLoop();
  assert.equal(controller.performFindHistory("undo", findInput, controller.findContextID), true);
  assert.equal(findInput.value, "old");
});

test("Find a newer composition generation survives an earlier settlement in the same context", async t => {
  const harness = makeFindController(t);
  const { controller, documentHandlers, findInput } = harness;
  const contextID = controller.findContextID;
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, "first", "insertCompositionText");
  documentHandlers.get("compositionend")({ target: findInput });
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, "second", "insertCompositionText");
  await waitForEventLoop();
  assert.equal(controller.findContextID, contextID);
  assert.equal(controller.findHistory.compositionActive, true);
  assert.equal(controller.findHistory.current.value, "second");
  assert.equal(controller.findHistory.undo.length, 0);
  documentHandlers.get("compositionend")({ target: findInput });
  await waitForEventLoop();
  assert.equal(controller.performFindHistory("undo", findInput, contextID), true);
  assert.equal(findInput.value, "first");
});

test("Find final composition input stays paired across compositionend", async t => {
  const harness = makeFindController(t);
  const { controller, documentHandlers, findInput } = harness;
  dispatchFindInput(harness, "a");
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, "a中", "insertCompositionText");
  beginFindInput(harness, { inputType: "insertFromComposition" });
  documentHandlers.get("compositionend")({ target: findInput });
  findInput.value = "a中文";
  findInput.setSelectionRange(3, 3);
  documentHandlers.get("input")({ target: findInput, inputType: "insertFromComposition", isTrusted: true });
  await waitForEventLoop();
  assert.equal(controller.performFindHistory("undo", findInput, controller.findContextID), true);
  assert.equal(findInput.value, "a");
  assert.equal(controller.performFindHistory("redo", findInput, controller.findContextID), true);
  assert.equal(findInput.value, "a中文");
});

test("the generated controller executes bounded pairing, cancellation notification, and failed-apply recovery", async t => {
  const bundle = await readFile(new URL("../../Sources/CodeMirror/web.bundle/codemirror.bundle.js", import.meta.url), "utf8");
  const exports = {};
  runInNewContext(bundle, {
    exports, module: { exports }, crypto: globalThis.crypto, Event, setTimeout, clearTimeout
  });
  const harness = makeFindController(t, exports.EditorController);
  const { controller, findInput, documentHandlers, findInputNotifications } = harness;
  dispatchFindInput(harness, "ab");
  findInput.setSelectionRange(0, 1, "backward");
  dispatchFindInput(harness, "xb");
  assert.equal(controller.performFindHistory("undo", findInput, controller.findContextID), true);
  assert.equal(findInput.value, "ab");
  assert.equal(findInput.selectionStart, 0);
  assert.equal(findInput.selectionDirection, "backward");
  beginFindInput(harness);
  await Promise.resolve();
  assert.notEqual(controller.findHistory.pendingBeforeInput, null);
  findInput.value = "ab!";
  findInput.setSelectionRange(3, 3);
  documentHandlers.get("input")({ target: findInput, inputType: "insertText", isTrusted: true });
  assert.equal(controller.performFindHistory("undo", findInput, controller.findContextID), true);
  assert.equal(findInput.value, "ab");
  beginFindInput(harness);
  await waitForEventLoop();
  assert.equal(controller.findHistory.pendingBeforeInput, null);
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, "中b", "insertCompositionText");
  documentHandlers.get("compositioncancel")({ target: findInput });
  await waitForEventLoop();
  assert.equal(findInput.value, "ab");
  assert.deepEqual(findInputNotifications.at(-1), { type: "input", value: "ab" });
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, "x".repeat(1024 * 1024 + 1), "insertCompositionText");
  assert.equal(controller.findHistory.current, null);
  assertFindHistoryBudget(controller);
  dispatchFindInput(harness, "baseline", "insertCompositionText");
  documentHandlers.get("compositionend")({ target: findInput });
  await waitForEventLoop();
  assert.equal(controller.findHistory.undo.length, 0);
  dispatchFindInput(harness, "baseline!");
  findInput.setSelectionRange = () => { throw new Error("selection unavailable"); };
  assert.equal(controller.performFindHistory("undo", findInput, controller.findContextID), false);
  assert.equal(controller.findHistory.current.value, findInput.value);
  assert.equal(controller.findHistory.undo.length, 0);
  assert.equal(controller.findHistory.redo.length, 0);
  assert.equal(harness.text, "document source");
  assert.equal(harness.messages.filter(message => message.type === "command").length, 0);
});

test("Find local history routes paired input transactions and rejects empty immutable targets", async () => {
  const harness = makeController("one");
  const { controller, documentHandlers, documentRef, findInput, messages } = harness;
  controller.configured = true;
  controller.initializing = false;
  controller.installFocusHandlers();
  controller.installCommandContextHandlers();
  documentRef.activeElement = controller.view.contentDOM;
  controller.reportCommandContext(true);
  controller.receive({
    type: "routeCommand",
    requestID: "content-undo",
    command: "undo",
    expectedRevision: 0,
    expectation: "contentOrCurrentFind"
  });
  assert.equal(messages.at(-1).result, "forwardedToHost");

  focusFindInput(harness);
  dispatchFindInput(harness, "q");
  await waitForEventLoop();
  const findContextID = controller.findContextID;
  controller.receive({
    type: "routeCommand",
    requestID: "find-undo",
    command: "undo",
    expectedRevision: 0,
    expectation: "find",
    findContextID
  });
  assert.equal(messages.at(-1).result, "handledByEmbeddedControl");
  assert.equal(findInput.value, "");
  controller.receive({
    type: "routeCommand",
    requestID: "find-empty-undo",
    command: "undo",
    expectedRevision: 0,
    expectation: "find",
    findContextID
  });
  assert.equal(messages.at(-1).result, "unavailable");
  assert.equal(findInput.value, "");
  controller.receive({
    type: "routeCommand",
    requestID: "find-redo",
    command: "redo",
    expectedRevision: 0,
    expectation: "find",
    findContextID
  });
  assert.equal(messages.at(-1).result, "handledByEmbeddedControl");
  assert.equal(findInput.value, "q");

  const forgedMessages = messages.length;
  controller.post({ type: "routeCommandResult", result: "forwardedToHost" });
  assert.equal(messages.length, forgedMessages + 1);
  documentRef.activeElement = controller.view.contentDOM;
  documentHandlers.get("focusout")({ target: findInput });
  controller.receive({
    type: "routeCommand",
    requestID: "other-undo",
    command: "undo",
    expectedRevision: 0,
    expectation: "contentOrCurrentFind"
  });
  assert.equal(messages.at(-1).result, "forwardedToHost");
  assert.equal(harness.text, "one");
  controller.destroy();
  assert.equal(documentHandlers.size, 0);
});

test("Find shortcuts consume empty history and never reach document commands", async () => {
  const harness = makeController("");
  const { controller, documentHandlers, documentRef, findInput, messages } = harness;
  controller.configured = true;
  controller.initializing = false;
  controller.installFocusHandlers();
  controller.installCommandContextHandlers();
  focusFindInput(harness);
  const event = {
    target: findInput,
    key: "z",
    metaKey: true,
    ctrlKey: false,
    altKey: false,
    shiftKey: false,
    prevented: false,
    stopped: false,
    preventDefault() { this.prevented = true; },
    stopImmediatePropagation() { this.stopped = true; }
  };
  documentHandlers.get("keydown")(event);
  await waitForEventLoop();
  assert.equal(event.prevented, true);
  assert.equal(event.stopped, true);
  assert.equal(messages.filter(message => message.type === "command").length, 0);
  documentRef.activeElement = controller.view.contentDOM;
  const contentEvent = { ...event, target: controller.view.contentDOM, prevented: false, stopped: false };
  documentHandlers.get("keydown")(contentEvent);
  assert.equal(contentEvent.prevented, false);
  controller.destroy();
});

test("Find history batches composition, restores selection, and clears redo on new input", async () => {
  const harness = makeController("");
  const { controller, documentHandlers, documentRef, findInput, messages } = harness;
  controller.configured = true;
  controller.initializing = false;
  controller.installFocusHandlers();
  controller.installCommandContextHandlers();
  focusFindInput(harness);
  dispatchFindInput(harness, "ab");
  findInput.setSelectionRange(1, 1);
  documentHandlers.get("selectionchange")();
  dispatchFindInput(harness, "😀", "insertText", 2);
  const selectionBeforeUndo = [findInput.selectionStart, findInput.selectionEnd];
  assert.deepEqual(selectionBeforeUndo, [2, 2]);
  controller.performFindHistory("undo", findInput, controller.findContextID);
  assert.equal(findInput.value, "ab");
  assert.deepEqual([findInput.selectionStart, findInput.selectionEnd], [1, 1]);
  controller.performFindHistory("redo", findInput, controller.findContextID);
  assert.equal(findInput.value, "😀");
  assert.deepEqual([findInput.selectionStart, findInput.selectionEnd], [2, 2]);

  documentHandlers.get("beforeinput")({ target: findInput, inputType: "insertText", isTrusted: true });
  findInput.value = "x";
  findInput.setSelectionRange(1, 1);
  documentHandlers.get("input")({ target: findInput, inputType: "insertText", isTrusted: true });
  assert.equal(controller.findHistory.redo.length, 0);

  const compositionStartValue = findInput.value;
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, `${compositionStartValue}中`, "insertCompositionText");
  const undoCountBeforeComposition = controller.findHistory.undo.length;
  documentHandlers.get("compositionend")({ target: findInput });
  await waitForEventLoop();
  assert.equal(controller.findHistory.undo.length, undoCountBeforeComposition + 1);
  controller.performFindHistory("undo", findInput, controller.findContextID);
  assert.equal(findInput.value, "x");
  const undoCountBeforeCancellation = controller.findHistory.undo.length;
  documentHandlers.get("compositionstart")({ target: findInput });
  dispatchFindInput(harness, "xy", "insertCompositionText");
  documentHandlers.get("compositioncancel")({ target: findInput });
  await waitForEventLoop();
  assert.equal(findInput.value, "x");
  assert.equal(controller.findHistory.undo.length, undoCountBeforeCancellation);
  assert.equal(messages.filter(message => message.type === "command").length, 0);
  documentRef.activeElement = controller.view.contentDOM;
  controller.destroy();
});

test("Find history adopts programmatic resets, retires on focus epoch, and enforces bounds", async () => {
  const harness = makeController("");
  const { controller, documentHandlers, documentRef, findInput } = harness;
  controller.configured = true;
  controller.initializing = false;
  controller.installFocusHandlers();
  controller.installCommandContextHandlers();
  focusFindInput(harness);
  for (let index = 0; index < 40; index += 1) {
    dispatchFindInput(harness, "x".repeat(index + 1));
  }
  assert.equal(controller.findHistory.undo.length, 32);
  findInput.value = "programmatic";
  documentHandlers.get("input")({ target: findInput, inputType: "insertText" });
  assert.equal(controller.findHistory.undo.length, 0);
  assert.equal(controller.findHistory.redo.length, 0);
  const oldContextID = controller.findContextID;
  documentHandlers.get("focusout")({ target: findInput });
  focusFindInput(harness);
  assert.notEqual(controller.findContextID, oldContextID);
  assert.equal(controller.findHistory.undo.length, 0);

  findInput.value = "x".repeat(1048577);
  documentHandlers.get("input")({ target: findInput, inputType: "insertText" });
  assert.equal(controller.findHistory.oversized, true);
  assert.equal(controller.findHistory.current, null);
  assert.equal(controller.findHistory.undo.length, 0);
  controller.performFindHistory("undo", findInput, controller.findContextID);
  assert.equal(findInput.value.length, 1048577);
  findInput.value = "bounded";
  documentHandlers.get("input")({ target: findInput, inputType: "insertText" });
  assert.equal(controller.findHistory.oversized, false);
  assert.equal(controller.findHistory.undo.length, 0);
  documentRef.activeElement = controller.view.contentDOM;
  controller.destroy();
  assert.equal(controller.findHistory, null);
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
  assert.deepEqual(messages.findLast(message => message.type === "flushResult"), { type: "flushResult", requestID: "flush", success: true, sessionID: "session", replicaID: "replica", loadID: "load" });
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
  assert.deepEqual(messages.findLast(message => message.type === "flushResult"), {
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
  assert.equal(messages.filter(message => message.type === "configured").length, 1);
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
