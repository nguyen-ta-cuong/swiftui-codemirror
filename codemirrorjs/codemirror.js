import { closeBrackets, closeBracketsKeymap, completionKeymap, autocompletion } from "@codemirror/autocomplete";
import { indentUnit, indentOnInput, bracketMatching, foldGutter, foldKeymap, syntaxHighlighting, defaultHighlightStyle } from "@codemirror/language";
import { json } from "@codemirror/lang-json";
import { xml } from "@codemirror/lang-xml";
import { graphql } from "cm6-graphql";
import { lintGutter, lintKeymap, setDiagnostics } from "@codemirror/lint";
import { EditorSelection, EditorState, Compartment } from "@codemirror/state";
import { EditorView, drawSelection, dropCursor, highlightActiveLine, highlightActiveLineGutter, highlightSpecialChars, keymap, lineNumbers } from "@codemirror/view";
import { openSearchPanel, search, searchKeymap } from "@codemirror/search";
import { oneDark } from "@codemirror/theme-one-dark";

export const MAX_ANALYSIS_BYTES = 1024 * 1024;

export function utf8ByteLength(value) {
  return new TextEncoder().encode(value).byteLength;
}

export function isAnalysisAvailable(value) {
  return utf8ByteLength(value) <= MAX_ANALYSIS_BYTES;
}

function makeDiagnostic(value, from, to, message, source, severity = "error") {
  const start = Math.max(0, Math.min(from, value.length));
  const end = Math.max(start, Math.min(to, value.length));
  return { from: start, to: end, severity, message, source };
}

function unavailableDiagnostic(value) {
  return makeDiagnostic(
    value,
    0,
    Math.min(1, value.length),
    "Syntax analysis and formatting are unavailable above 1 MiB; the source remains fully editable.",
    "CodeMirror",
    "info"
  );
}

function jsonDiagnostics(value) {
  try {
    JSON.parse(value);
    return [];
  } catch (error) {
    const position = Number(error?.message?.match(/position (\d+)/i)?.[1]);
    const from = Number.isInteger(position) ? position : Math.max(0, value.length - 1);
    return [makeDiagnostic(value, from, from + 1, error?.message || "JSON syntax is invalid.", "JSON")];
  }
}

function xmlDiagnostics(value) {
  const diagnostics = [];
  const stack = [];
  const report = (from, to, message) => {
    if (diagnostics.length < 8) {
      diagnostics.push(makeDiagnostic(value, from, to, message, "XML"));
    }
  };
  let index = 0;
  while (index < value.length) {
    const open = value.indexOf("<", index);
    if (open < 0) {
      break;
    }
    if (value.startsWith("<!--", open)) {
      const close = value.indexOf("-->", open + 4);
      if (close < 0) {
        report(open, value.length, "XML comment is not closed.");
        break;
      }
      index = close + 3;
      continue;
    }
    if (value.startsWith("<![CDATA[", open)) {
      const close = value.indexOf("]]>", open + 9);
      if (close < 0) {
        report(open, value.length, "XML CDATA section is not closed.");
        break;
      }
      index = close + 3;
      continue;
    }
    if (value.startsWith("<?", open)) {
      const close = value.indexOf("?>", open + 2);
      if (close < 0) {
        report(open, value.length, "XML processing instruction is not closed.");
        break;
      }
      index = close + 2;
      continue;
    }
    let quote = null;
    let close = open + 1;
    for (; close < value.length; close += 1) {
      const character = value[close];
      if (quote) {
        if (character === quote) {
          quote = null;
        }
      } else if (character === '"' || character === "'") {
        quote = character;
      } else if (character === ">") {
        break;
      }
    }
    if (close >= value.length) {
      report(open, value.length, "XML tag is not closed.");
      break;
    }
    const body = value.slice(open + 1, close);
    if (body.startsWith("!")) {
      index = close + 1;
      continue;
    }
    const closing = /^\s*\/\s*([A-Za-z_][\w:.-]*)\s*$/.exec(body);
    if (closing) {
      const expected = stack.pop();
      if (!expected) {
        report(open, close + 1, `Unexpected closing tag </${closing[1]}>.`);
      } else if (expected.name !== closing[1]) {
        report(open, close + 1, `Closing tag </${closing[1]}> does not match <${expected.name}>.`);
      }
      index = close + 1;
      continue;
    }
    const opening = /^\s*([A-Za-z_][\w:.-]*)\b/.exec(body);
    if (!opening) {
      report(open, close + 1, "XML tag name is missing or invalid.");
      index = close + 1;
      continue;
    }
    if (!/\/\s*$/.test(body)) {
      stack.push({ name: opening[1], from: open });
    }
    index = close + 1;
  }
  while (stack.length > 0 && diagnostics.length < 8) {
    const unclosed = stack.pop();
    report(unclosed.from, Math.min(value.length, unclosed.from + unclosed.name.length + 2), `Opening tag <${unclosed.name}> is not closed.`);
  }
  return diagnostics;
}

function graphqlDiagnostics(value) {
  const diagnostics = [];
  const stack = [];
  const report = (from, to, message) => {
    if (diagnostics.length < 8) {
      diagnostics.push(makeDiagnostic(value, from, to, message, "GraphQL"));
    }
  };
  const matching = { "}": "{", "]": "[", ")": "(" };
  let index = 0;
  while (index < value.length) {
    const character = value[index];
    if (character === "#") {
      const lineEnd = value.indexOf("\n", index);
      index = lineEnd < 0 ? value.length : lineEnd + 1;
      continue;
    }
    if (character === '"') {
      if (value.startsWith('"""', index)) {
        const close = value.indexOf('"""', index + 3);
        if (close < 0) {
          report(index, value.length, "GraphQL block string is not closed.");
          break;
        }
        index = close + 3;
        continue;
      }
      const start = index;
      index += 1;
      let closed = false;
      while (index < value.length) {
        if (value[index] === "\\") {
          index += 2;
          continue;
        }
        if (value[index] === '"') {
          closed = true;
          index += 1;
          break;
        }
        if (value[index] === "\n" || value[index] === "\r") {
          report(start, index + 1, "GraphQL string cannot contain an unescaped line break.");
          break;
        }
        index += 1;
      }
      if (!closed && index >= value.length) {
        report(start, value.length, "GraphQL string is not closed.");
      }
      continue;
    }
    if (Object.hasOwn(matching, character)) {
      const expected = matching[character];
      const previous = stack.pop();
      if (!previous || previous.character !== expected) {
        report(index, index + 1, `Unexpected GraphQL closing delimiter ${character}.`);
      }
      index += 1;
      continue;
    }
    if (character === "{" || character === "[" || character === "(") {
      stack.push({ character, from: index });
    }
    index += 1;
  }
  while (stack.length > 0 && diagnostics.length < 8) {
    const unclosed = stack.pop();
    report(unclosed.from, Math.min(value.length, unclosed.from + 1), `GraphQL delimiter ${unclosed.character} is not closed.`);
  }
  return diagnostics;
}

export function documentDiagnostics(language, value) {
  if (!isAnalysisAvailable(value)) {
    return [unavailableDiagnostic(value)];
  }
  switch (language) {
  case "json":
    return jsonDiagnostics(value);
  case "xml":
    return xmlDiagnostics(value);
  case "graphql":
    return graphqlDiagnostics(value);
  default:
    return [];
  }
}

export function jsonLiteralCompletion(context) {
  const word = context.matchBefore(/[A-Za-z]*/);
  if (!context.explicit && (!word || word.from === word.to)) {
    return null;
  }
  return {
    from: word?.from ?? context.pos,
    options: [
      { label: "true", type: "keyword", detail: "JSON boolean" },
      { label: "false", type: "keyword", detail: "JSON boolean" },
      { label: "null", type: "keyword", detail: "JSON null" }
    ],
    validFor: /^[A-Za-z]*$/
  };
}

function isUTF16Boundary(value, offset) {
  if (!Number.isInteger(offset) || offset < 0 || offset > value.length) {
    return false;
  }
  if (offset === 0 || offset === value.length) {
    return true;
  }
  const previous = value.charCodeAt(offset - 1);
  const next = value.charCodeAt(offset);
  return !(previous >= 0xd800 && previous <= 0xdbff && next >= 0xdc00 && next <= 0xdfff);
}

export function validateChanges(value, changes) {
  let previousEnd = 0;
  for (const change of changes) {
    if (!Number.isInteger(change.fromUTF16) || !Number.isInteger(change.toUTF16)) {
      return { valid: false, reason: "range" };
    }
    if (change.fromUTF16 < previousEnd || change.fromUTF16 > change.toUTF16) {
      return { valid: false, reason: "order" };
    }
    if (!isUTF16Boundary(value, change.fromUTF16) || !isUTF16Boundary(value, change.toUTF16)) {
      return { valid: false, reason: "surrogate" };
    }
    previousEnd = change.toUTF16;
  }
  return { valid: true, reason: null };
}

export function applyChanges(value, changes) {
  const validation = validateChanges(value, changes);
  if (!validation.valid) {
    throw new Error(`Invalid change: ${validation.reason}`);
  }
  let result = value;
  for (const change of [...changes].reverse()) {
    result = result.slice(0, change.fromUTF16) + change.insertedText + result.slice(change.toUTF16);
  }
  return result;
}

function tokenizeJSON(value) {
  const tokens = [];
  let index = 0;
  while (index < value.length) {
    const character = value[index];
    if (/\s/.test(character)) {
      index += 1;
      continue;
    }
    if (character === '"') {
      const start = index;
      index += 1;
      let escaped = false;
      let closed = false;
      while (index < value.length) {
        const current = value[index];
        if (escaped) {
          escaped = false;
        } else if (current === "\\") {
          escaped = true;
        } else if (current === '"') {
          index += 1;
          closed = true;
          break;
        }
        index += 1;
      }
      if (!closed) {
        return null;
      }
      tokens.push({ kind: "value", value: value.slice(start, index) });
      continue;
    }
    if ("{}[],:".includes(character)) {
      tokens.push({ kind: character, value: character });
      index += 1;
      continue;
    }
    const start = index;
    while (index < value.length && !/[\s{}[\],:]/.test(value[index])) {
      index += 1;
    }
    tokens.push({ kind: "value", value: value.slice(start, index) });
  }
  return tokens;
}

export function formatJSON(value) {
  try {
    JSON.parse(value);
  } catch {
    return { available: false, text: value, diagnostic: "JSON syntax is incomplete or invalid." };
  }
  const tokens = tokenizeJSON(value);
  if (!tokens) {
    return { available: false, text: value, diagnostic: "JSON string syntax is incomplete." };
  }
  const lines = [];
  let current = "";
  let indentation = 0;
  const indentationText = () => "  ".repeat(indentation);
  const flush = () => {
    if (current.length > 0) {
      lines.push(indentationText() + current);
      current = "";
    }
  };
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    const next = tokens[index + 1]?.kind;
    if (token.kind === "{" || token.kind === "[") {
      current += token.value;
      if (next !== "}" && next !== "]") {
        flush();
        indentation += 1;
      }
      continue;
    }
    if (token.kind === "}" || token.kind === "]") {
      if (current === "{" || current === "[") {
        current += token.value;
        continue;
      }
      flush();
      indentation = Math.max(0, indentation - 1);
      current = token.value;
      if (next !== "," && next !== "}" && next !== "]") {
        flush();
      }
      continue;
    }
    if (token.kind === ",") {
      current += ",";
      flush();
      continue;
    }
    if (token.kind === ":") {
      current = current.trimEnd() + ": ";
      continue;
    }
    current += token.value;
  }
  flush();
  return { available: true, text: lines.join("\n"), diagnostic: null };
}

function lightTheme(increaseContrast) {
  const foreground = increaseContrast ? "#111111" : "#24292f";
  const background = increaseContrast ? "#ffffff" : "#fbfbfc";
  return EditorView.theme({
    "&": { colorScheme: "light", backgroundColor: background, color: foreground },
    ".cm-content": { caretColor: foreground },
    ".cm-gutters": { backgroundColor: background, color: increaseContrast ? "#333333" : "#6e7781", border: "none" },
    ".cm-activeLine": { backgroundColor: increaseContrast ? "#eeeeee" : "#f1f3f5" },
    ".cm-activeLineGutter": { backgroundColor: increaseContrast ? "#eeeeee" : "#f1f3f5" }
  });
}

function darkTheme(increaseContrast) {
  return [oneDark, EditorView.theme({
    "&": { colorScheme: "dark", backgroundColor: increaseContrast ? "#111111" : "#1e1e1e" },
    ".cm-content": { caretColor: increaseContrast ? "#ffffff" : "#d4d4d4" }
  })];
}

function languageExtension(language, text) {
  if (!isAnalysisAvailable(text)) {
    return [];
  }
  switch (language) {
  case "json":
    return json();
  case "xml":
    return xml();
  case "graphql":
    return graphql();
  default:
    return [];
  }
}

function selectionValue(selection) {
  return {
    anchorUTF16: selection.anchor,
    headUTF16: selection.head
  };
}

function compositionValue(phase) {
  if (phase === "none") {
    return { phase: "none", id: null };
  }
  return { phase: phase.phase, id: phase.id };
}

function twoSpaceIndent(view) {
  const changes = [];
  for (const range of view.state.selection.ranges) {
    const first = view.state.doc.lineAt(range.from).number;
    const last = view.state.doc.lineAt(range.to).number;
    for (let lineNumber = first; lineNumber <= last; lineNumber += 1) {
      changes.push({ from: view.state.doc.line(lineNumber).from, insert: "  " });
    }
  }
  if (changes.length > 0) {
    view.dispatch({ changes });
  }
  return true;
}

function twoSpaceOutdent(view) {
  const changes = [];
  for (const range of view.state.selection.ranges) {
    const first = view.state.doc.lineAt(range.from).number;
    const last = view.state.doc.lineAt(range.to).number;
    for (let lineNumber = first; lineNumber <= last; lineNumber += 1) {
      const line = view.state.doc.line(lineNumber);
      const whitespace = line.text.match(/^ {1,2}/)?.[0] ?? "";
      if (whitespace.length > 0) {
        changes.push({ from: line.from, to: line.from + whitespace.length });
      }
    }
  }
  if (changes.length > 0) {
    view.dispatch({ changes });
  }
  return true;
}

class EditorController {
  constructor(postMessage, documentRef = document) {
    this.postMessage = postMessage;
    this.documentRef = documentRef;
    this.view = null;
    this.sessionID = null;
    this.replicaID = null;
    this.loadID = null;
    this.configuration = {
      language: "text",
      isReadOnly: false,
      wrapsLines: false,
      showsLineNumbers: true,
      maximumPendingTransactions: 64,
      appearance: { colorScheme: "light", increaseContrast: false, reduceMotion: false, reduceTransparency: false },
      editorName: "Code editor"
    };
    this.hostText = "";
    this.hostRevision = 0;
    this.localRevision = 0;
    this.pendingTransactions = [];
    this.pendingAcks = new Map();
    this.deferredLocalSync = false;
    this.flushRequests = new Map();
    this.configured = false;
    this.initializing = true;
    this.localEditBeforeConfiguration = false;
    this.applyingHostChange = false;
    this.divergent = false;
    this.composition = { phase: "none", id: null };
    this.compositionActive = false;
    this.compositionEnding = false;
    this.compositionSettlementTimer = null;
    this.diagnosticsPanel = null;
    this.diagnosticsScheduled = false;
    this.languageCompartment = new Compartment();
    this.appearanceCompartment = new Compartment();
    this.lineNumberCompartment = new Compartment();
    this.readOnlyCompartment = new Compartment();
    this.lineWrappingCompartment = new Compartment();
    this.foldCompartment = new Compartment();
    this.listenerCompartment = new Compartment();
    this.handlers = [];
  }

  mount() {
    const updateListener = EditorView.updateListener.of(update => this.handleUpdate(update));
    if (this.documentRef.body && this.documentRef.createElement) {
      this.diagnosticsPanel = this.documentRef.createElement("aside");
      this.diagnosticsPanel.className = "cm-host-diagnostics";
      this.diagnosticsPanel.setAttribute("role", "status");
      this.diagnosticsPanel.setAttribute("aria-live", "polite");
      this.diagnosticsPanel.tabIndex = 0;
      this.diagnosticsPanel.hidden = true;
      this.documentRef.body.appendChild(this.diagnosticsPanel);
    }
    this.view = new EditorView({
      doc: "",
      extensions: [
        indentUnit.of("  "),
        drawSelection(),
        dropCursor(),
        highlightSpecialChars(),
        highlightActiveLine(),
        highlightActiveLineGutter(),
        indentOnInput(),
        bracketMatching(),
        closeBrackets(),
        autocompletion({ override: [context => this.configuration.language === "json" ? jsonLiteralCompletion(context) : null] }),
        lintGutter(),
        search(),
        syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        keymap.of([
          { key: "Ctrl-Tab", run: () => this.sendFocusTraversal(true) },
          { key: "Ctrl-Shift-Tab", run: () => this.sendFocusTraversal(false) },
          { key: "Tab", run: twoSpaceIndent },
          { key: "Shift-Tab", run: twoSpaceOutdent },
          { key: "Mod-z", run: () => this.sendCommand("undo") },
          { key: "Mod-y", run: () => this.sendCommand("redo") },
          { key: "Mod-Shift-z", run: () => this.sendCommand("redo") },
          { key: "Mod-f", run: view => { openSearchPanel(view); return true; } },
          ...closeBracketsKeymap,
          ...completionKeymap,
          ...foldKeymap,
          ...lintKeymap,
          ...searchKeymap
        ]),
        this.languageCompartment.of([]),
        this.appearanceCompartment.of(lightTheme(false)),
        this.lineNumberCompartment.of(lineNumbers()),
        this.readOnlyCompartment.of(EditorState.readOnly.of(true)),
        this.lineWrappingCompartment.of([]),
        this.foldCompartment.of([]),
        this.listenerCompartment.of(updateListener)
      ],
      parent: this.documentRef.body
    });
    this.view.dom.setAttribute("aria-busy", "true");
    this.installCompositionHandlers();
    this.post({ type: "ready" });
  }

  post(message) {
    if (this.sessionID && this.replicaID && this.loadID && message.type !== "ready") {
      this.postMessage({
        ...message,
        sessionID: this.sessionID,
        replicaID: this.replicaID,
        loadID: this.loadID
      });
      return;
    }
    this.postMessage(message);
  }

  receive(command) {
    if (!command || typeof command.type !== "string") {
      return;
    }
    switch (command.type) {
    case "configure":
      this.configure(command);
      break;
    case "updateConfiguration":
      this.updateConfiguration(command.configuration);
      break;
    case "apply":
      this.applySnapshot(command, false);
      break;
    case "reconcile":
      this.applySnapshot(command, Boolean(command.preserveLocalChanges));
      break;
    case "acknowledge":
      this.acknowledge(Number(command.revision));
      break;
    case "focus":
      this.view?.focus();
      break;
    case "showFind":
      if (this.view) {
        openSearchPanel(this.view);
      }
      break;
    case "format":
      this.format(command.requestID);
      break;
    case "flush":
      this.flush(command.requestID);
      break;
    case "selection":
      this.applySelection(command.selection);
      break;
    case "invalidate":
      this.destroy();
      break;
    default:
      this.post({ type: "failure", code: "transportFailure" });
    }
  }

  configure(command) {
    this.initializing = true;
    this.configured = false;
    this.sessionID = command.sessionID;
    this.replicaID = command.replicaID;
    this.loadID = command.loadID;
    this.hostText = command.text;
    this.hostRevision = Number(command.revision);
    this.localRevision = this.hostRevision;
    this.configuration = command.configuration;
    this.updateConfiguration(this.configuration);
    this.replaceDocument(command.text, command.selections, true);
    this.localEditBeforeConfiguration = false;
    this.initializing = false;
    this.configured = true;
    this.updateConfiguration(this.configuration);
    this.scheduleDiagnostics();
    this.post({ type: "configured" });
  }

  updateConfiguration(configuration) {
    if (!configuration) {
      return;
    }
    this.configuration = { ...this.configuration, ...configuration };
    if (!this.view) {
      return;
    }
    const text = this.view.state.doc.toString();
    this.view.dispatch({
      effects: [
        this.languageCompartment.reconfigure(languageExtension(this.configuration.language, text)),
        this.appearanceCompartment.reconfigure(this.configuration.appearance.colorScheme === "dark" ? darkTheme(this.configuration.appearance.increaseContrast) : lightTheme(this.configuration.appearance.increaseContrast)),
        this.lineNumberCompartment.reconfigure(this.configuration.showsLineNumbers ? lineNumbers() : []),
        this.readOnlyCompartment.reconfigure(this.initializing || this.configuration.isReadOnly ? EditorState.readOnly.of(true) : []),
        this.lineWrappingCompartment.reconfigure(this.configuration.wrapsLines ? EditorView.lineWrapping : []),
        this.foldCompartment.reconfigure(this.configuration.showsLineNumbers ? foldGutter() : [])
      ]
    });
    const name = this.configuration.editorName || "Code editor";
    this.view.dom.setAttribute("aria-label", name);
    this.view.dom.setAttribute("role", "textbox");
    this.view.dom.setAttribute("spellcheck", "false");
    this.view.dom.setAttribute("aria-busy", this.initializing ? "true" : "false");
    this.view.dom.setAttribute("aria-readonly", (this.initializing || this.configuration.isReadOnly) ? "true" : "false");
    this.view.dom.style.setProperty("font-family", "ui-monospace, SFMono-Regular, Menlo, monospace");
    this.view.dom.style.setProperty("transition", this.configuration.appearance.reduceMotion ? "none" : "opacity 120ms ease");
    this.view.dom.style.setProperty("background", this.configuration.appearance.reduceTransparency ? "Canvas" : "transparent");
    this.scheduleDiagnostics();
  }

  scheduleDiagnostics() {
    if (this.diagnosticsScheduled) {
      return;
    }
    this.diagnosticsScheduled = true;
    Promise.resolve().then(() => {
      this.diagnosticsScheduled = false;
      this.refreshDiagnostics();
    });
  }

  refreshDiagnostics() {
    if (!this.view || !this.configured) {
      return;
    }
    const text = this.view.state.doc.toString();
    const diagnostics = documentDiagnostics(this.configuration.language, text);
    this.view.dispatch(setDiagnostics(this.view.state, diagnostics));
    if (!this.diagnosticsPanel) {
      return;
    }
    this.diagnosticsPanel.textContent = diagnostics
      .map(diagnostic => `${diagnostic.severity}: ${diagnostic.message}`)
      .join("\n");
    this.diagnosticsPanel.hidden = diagnostics.length === 0;
    this.diagnosticsPanel.classList.toggle(
      "cm-host-diagnostics-info",
      diagnostics.some(diagnostic => diagnostic.severity === "info")
    );
  }

  handleUpdate(update) {
    if (!update.docChanged) {
      if (update.selectionSet && this.configured && !this.applyingHostChange && !this.deferredLocalSync) {
        this.post({ type: "selection", revision: this.localRevision, selection: selectionValue(update.state.selection.main) });
      }
      return;
    }
    this.scheduleDiagnostics();
    if (this.applyingHostChange) {
      return;
    }
    if (!this.configured) {
      this.localEditBeforeConfiguration = true;
      return;
    }
    const changes = [];
    update.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
      changes.push({
        fromUTF16: fromA,
        toUTF16: toA,
        insertedText: inserted.toString(),
        removedText: update.startState.doc.sliceString(fromA, toA)
      });
    });
    const baseRevision = this.localRevision;
    const revision = baseRevision + 1;
    this.localRevision = revision;
    const transaction = {
      type: "transaction",
      baseRevision,
      revision,
      changes,
      selectionBefore: selectionValue(update.startState.selection.main),
      selectionAfter: selectionValue(update.state.selection.main),
      composition: compositionValue(this.composition)
    };
    if (this.deferredLocalSync) {
      this.settleCompositionAfterUpdate();
      this.tryFinishFlushes();
      return;
    }
    const maximum = Math.max(1, Number(this.configuration.maximumPendingTransactions) || 64);
    if (this.pendingAcks.size + this.pendingTransactions.length >= maximum) {
      this.deferredLocalSync = true;
      this.pendingTransactions = [];
      this.settleCompositionAfterUpdate();
      this.tryFinishFlushes();
      return;
    }
    this.enqueueTransaction(transaction);
    if (this.composition.phase === "ended") {
      this.composition = { phase: "none", id: null };
    } else if (this.compositionActive && this.composition.phase === "began") {
      this.composition = { phase: "updated", id: this.composition.id };
    }
    this.settleCompositionAfterUpdate();
    this.scheduleDiagnostics();
    this.tryFinishFlushes();
  }

  enqueueTransaction(transaction) {
    this.pendingTransactions.push(transaction);
    this.pumpTransactions();
  }

  pumpTransactions() {
    const maximum = Math.max(1, Number(this.configuration.maximumPendingTransactions) || 64);
    while (this.pendingTransactions.length > 0 && this.pendingAcks.size < maximum) {
      const transaction = this.pendingTransactions.shift();
      this.pendingAcks.set(transaction.revision, transaction);
      this.post(transaction);
    }
  }

  acknowledge(revision) {
    const transaction = this.pendingAcks.get(revision);
    if (!transaction) {
      return;
    }
    try {
      this.hostText = applyChanges(this.hostText, transaction.changes);
    } catch {
      this.deferredLocalSync = true;
    }
    this.pendingAcks.delete(revision);
    this.hostRevision = Math.max(this.hostRevision, revision);
    this.pumpTransactions();
    this.tryFinishFlushes();
  }

  applySnapshot(command, preserveLocalChanges) {
    const hasLocalWork = this.deferredLocalSync || this.pendingAcks.size > 0 || this.pendingTransactions.length > 0 || this.localRevision > Number(command.revision);
    if (preserveLocalChanges && hasLocalWork) {
      this.divergent = true;
      this.post({ type: "failure", code: "conflictingEdit" });
      this.tryFinishFlushes();
      return;
    }
    this.replaceDocument(command.text, command.selections, true);
    this.hostText = command.text;
    this.hostRevision = Number(command.revision);
    this.localRevision = this.hostRevision;
    this.pendingAcks.clear();
    this.pendingTransactions = [];
    this.deferredLocalSync = false;
    this.divergent = false;
    this.scheduleDiagnostics();
    this.tryFinishFlushes();
  }

  replaceDocument(text, selections, suppressEvents) {
    if (!this.view || this.view.state.doc.toString() === text) {
      this.applySelections(selections);
      return;
    }
    this.applyingHostChange = suppressEvents;
    this.view.dispatch({ changes: { from: 0, to: this.view.state.doc.length, insert: text } });
    this.applyingHostChange = false;
    this.applySelections(selections);
  }

  applySelections(selections) {
    if (!this.view || !Array.isArray(selections)) {
      return;
    }
    const own = selections.find(selection => selection.replicaID === this.replicaID);
    if (!own) {
      return;
    }
    const limit = this.view.state.doc.length;
    const anchor = Math.min(Math.max(Number(own.anchorUTF16), 0), limit);
    const head = Math.min(Math.max(Number(own.headUTF16), 0), limit);
    this.applyingHostChange = true;
    this.view.dispatch({ selection: EditorSelection.single(anchor, head) });
    this.applyingHostChange = false;
  }

  applySelection(selection) {
    if (!this.view || !selection) {
      return;
    }
    const limit = this.view.state.doc.length;
    const anchor = Math.min(Math.max(Number(selection.anchorUTF16), 0), limit);
    const head = Math.min(Math.max(Number(selection.headUTF16), 0), limit);
    this.applyingHostChange = true;
    this.view.dispatch({ selection: EditorSelection.single(anchor, head) });
    this.applyingHostChange = false;
  }

  sendFullLocalTransaction(baseText, localText) {
    const baseRevision = this.hostRevision;
    const revision = baseRevision + 1;
    this.localRevision = revision;
    this.enqueueTransaction({
      type: "transaction",
      baseRevision,
      revision,
      changes: [{ fromUTF16: 0, toUTF16: baseText.length, insertedText: localText, removedText: baseText }],
      selectionBefore: { anchorUTF16: 0, headUTF16: 0 },
      selectionAfter: selectionValue(this.view.state.selection.main),
      composition: { phase: "none", id: null }
    });
  }

  sendCommand(command) {
    if (!this.configured) {
      return true;
    }
    this.post({ type: "command", revision: this.localRevision, command });
    return true;
  }

  sendFocusTraversal(forward) {
    if (!this.configured) {
      return true;
    }
    this.post({ type: "focusTraversal", direction: forward ? "next" : "previous" });
    return true;
  }

  format(requestID) {
    const text = this.view?.state.doc.toString() ?? "";
    if (this.configuration.language !== "json" || !isAnalysisAvailable(text)) {
      this.post({ type: "formatResult", requestID, success: false });
      return;
    }
    const result = formatJSON(text);
    if (!result.available) {
      this.post({ type: "formatResult", requestID, success: false });
      return;
    }
    if (result.text !== text) {
      this.view.dispatch({ changes: { from: 0, to: this.view.state.doc.length, insert: result.text } });
    }
    this.scheduleDiagnostics();
    this.post({ type: "formatResult", requestID, success: true });
  }

  flush(requestID) {
    this.flushRequests.set(requestID, true);
    this.tryFinishFlushes();
  }

  tryFinishFlushes() {
    if (this.divergent) {
      for (const requestID of this.flushRequests.keys()) {
        this.flushRequests.delete(requestID);
        this.post({ type: "flushResult", requestID, success: false, code: "conflictingEdit" });
      }
      return;
    }
    if (this.compositionActive || this.compositionEnding || this.pendingTransactions.length > 0 || this.pendingAcks.size > 0) {
      return;
    }
    if (this.deferredLocalSync) {
      this.deferredLocalSync = false;
      const localText = this.view?.state.doc.toString() ?? "";
      this.sendFullLocalTransaction(this.hostText, localText);
      return;
    }
    for (const requestID of this.flushRequests.keys()) {
      this.flushRequests.delete(requestID);
      this.post({ type: "flushResult", requestID, success: true });
    }
  }

  installCompositionHandlers() {
    if (!this.view) {
      return;
    }
    const start = () => {
      const id = crypto.randomUUID();
      this.composition = { phase: "began", id };
      this.compositionActive = true;
    };
    const update = () => {
      if (this.compositionActive && this.composition.id) {
        this.composition = { phase: "updated", id: this.composition.id };
      }
    };
    const end = () => {
      if (this.compositionActive && this.composition.id) {
        this.composition = { phase: "ended", id: this.composition.id };
      }
      this.compositionEnding = true;
      this.compositionActive = false;
      this.scheduleCompositionSettlement();
    };
    this.view.dom.addEventListener("compositionstart", start);
    this.view.dom.addEventListener("compositionupdate", update);
    this.view.dom.addEventListener("compositionend", end);
    this.handlers = [["compositionstart", start], ["compositionupdate", update], ["compositionend", end]];
  }

  scheduleCompositionSettlement() {
    if (this.compositionSettlementTimer !== null) {
      return;
    }
    this.compositionSettlementTimer = setTimeout(() => {
      this.compositionSettlementTimer = null;
      if (!this.compositionEnding) {
        return;
      }
      this.compositionEnding = false;
      this.composition = { phase: "none", id: null };
      this.tryFinishFlushes();
    }, 0);
  }

  settleCompositionAfterUpdate() {
    if (!this.compositionEnding) {
      return;
    }
    this.compositionEnding = false;
    this.composition = { phase: "none", id: null };
    if (this.compositionSettlementTimer !== null) {
      clearTimeout(this.compositionSettlementTimer);
      this.compositionSettlementTimer = null;
    }
  }

  destroy() {
    if (this.view) {
      for (const [name, handler] of this.handlers) {
        this.view.dom.removeEventListener(name, handler);
      }
      this.view.destroy();
    }
    if (this.compositionSettlementTimer !== null) {
      clearTimeout(this.compositionSettlementTimer);
      this.compositionSettlementTimer = null;
    }
    this.diagnosticsPanel?.remove();
    this.diagnosticsPanel = null;
    this.diagnosticsScheduled = false;
    this.view = null;
    this.flushRequests.clear();
    this.pendingTransactions = [];
    this.pendingAcks.clear();
    this.deferredLocalSync = false;
  }
}

let controller;

export function start(postMessage = message => window.webkit.messageHandlers.codeMirrorHost.postMessage(message), documentRef = document) {
  controller = new EditorController(postMessage, documentRef);
  controller.mount();
  return controller;
}

export function receive(command) {
  controller?.receive(command);
}

export { EditorController };
