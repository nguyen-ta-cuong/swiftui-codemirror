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
const MAX_FIND_HISTORY_SNAPSHOTS = 32;
const MAX_FIND_HISTORY_UNITS = 1024 * 1024;
const MAX_PENDING_FLUSH_REQUESTS = 32;
const MAX_REPORTED_HEIGHT = 4096;

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

function diagnosticPresentationPolicy(value) {
  if (!value || typeof value !== "object") {
    return { allowsEmpty: false, consequence: null };
  }
  return {
    allowsEmpty: value.allowsEmpty === true,
    consequence: typeof value.consequence === "string" ? value.consequence : null
  };
}

function presentedDiagnostics(language, value, configuration) {
  const diagnostics = documentDiagnostics(language, value);
  const policy = diagnosticPresentationPolicy(configuration?.diagnosticPresentationPolicy);
  const filtered = policy.allowsEmpty && value.length === 0
    ? diagnostics.filter(diagnostic => diagnostic.severity !== "error")
    : diagnostics;
  if (!policy.consequence) {
    return filtered;
  }
  return filtered.map(diagnostic => diagnostic.severity === "error"
    ? { ...diagnostic, message: `${diagnostic.message} ${policy.consequence}` }
    : diagnostic);
}

function normalizedHeightPolicy(value) {
  if (value?.mode === "contentSized"
    && Number.isInteger(value.minimumVisibleRows)
    && Number.isInteger(value.maximumVisibleRows)
    && value.minimumVisibleRows >= 0
    && value.maximumVisibleRows >= value.minimumVisibleRows) {
    return {
      mode: "contentSized",
      minimumVisibleRows: value.minimumVisibleRows,
      maximumVisibleRows: value.maximumVisibleRows
    };
  }
  if (value?.mode === "fillsAvailableScrollViewport") {
    const minimumVisibleRows = Number(value.minimumVisibleRows);
    return {
      mode: "fillsAvailableScrollViewport",
      minimumVisibleRows: Number.isFinite(minimumVisibleRows)
        ? Math.max(0, Math.floor(minimumVisibleRows))
        : 0
    };
  }
  return { mode: "fillsAvailableScrollViewport", minimumVisibleRows: 0 };
}

function isValidMeasurementID(value) {
  return typeof value === "string"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function styleValue(style, property) {
  if (typeof style.getPropertyValue === "function") {
    return style.getPropertyValue(property);
  }
  return style[property] || "";
}

function setStyleValue(style, property, value) {
  if (typeof style.setProperty === "function") {
    style.setProperty(property, value);
  } else {
    style[property] = value;
  }
}

function restoreStyleValue(style, property, value) {
  if (value) {
    setStyleValue(style, property, value);
  } else if (typeof style.removeProperty === "function") {
    style.removeProperty(property);
  } else {
    style[property] = "";
  }
}

function withNaturalEditorHeight(editor, scrollDOM, measure) {
  const temporary = [
    [editor, "flex", "none"],
    [editor, "height", "auto"],
    [editor, "min-height", "0"],
    [editor, "max-height", "none"],
    [scrollDOM, "height", "auto"],
    [scrollDOM, "min-height", "0"],
    [scrollDOM, "max-height", "none"],
    [scrollDOM, "overflow-y", "visible"]
  ];
  const previous = [];
  for (const [element, property, value] of temporary) {
    if (!element?.style) {
      continue;
    }
    previous.push({ element, property, value: styleValue(element.style, property) });
    setStyleValue(element.style, property, value);
  }
  try {
    return measure();
  } finally {
    for (const entry of previous.reverse()) {
      restoreStyleValue(entry.element.style, entry.property, entry.value);
    }
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

function compareJSONKeys(left, right) {
  const length = Math.min(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const leftCode = left.charCodeAt(index);
    const rightCode = right.charCodeAt(index);
    if (leftCode !== rightCode) {
      return leftCode - rightCode;
    }
  }
  return left.length - right.length;
}

function parseJSONTokens(tokens) {
  const root = { kind: "root", state: "value", value: null };
  const stack = [root];
  const canAcceptValue = frame => (
    (frame.kind === "root" && frame.state === "value")
    || (frame.kind === "array" && frame.state === "valueOrEnd")
    || (frame.kind === "object" && frame.state === "value")
  );
  const attachValue = node => {
    const frame = stack.at(-1);
    if (frame.kind === "root") {
      frame.value = node;
      frame.state = "done";
    } else if (frame.kind === "array") {
      frame.node.elements.push(node);
      frame.state = "commaOrEnd";
    } else {
      frame.node.members.push({
        key: frame.pendingKey,
        keyToken: frame.pendingKeyToken,
        value: node,
        index: frame.node.members.length
      });
      frame.pendingKey = null;
      frame.pendingKeyToken = null;
      frame.state = "commaOrEnd";
    }
  };
  const closeContainer = kind => {
    const frame = stack.at(-1);
    if (frame.kind !== kind || (frame.state !== "valueOrEnd" && frame.state !== "keyOrEnd"
      && frame.state !== "commaOrEnd")) {
      return false;
    }
    stack.pop();
    attachValue(frame.node);
    return true;
  };

  for (const token of tokens) {
    const frame = stack.at(-1);
    if (token.kind === "{") {
      if (!canAcceptValue(frame)) {
        return null;
      }
      stack.push({
        kind: "object",
        node: { kind: "object", members: [] },
        state: "keyOrEnd",
        pendingKey: null,
        pendingKeyToken: null
      });
      continue;
    }
    if (token.kind === "[") {
      if (!canAcceptValue(frame)) {
        return null;
      }
      stack.push({
        kind: "array",
        node: { kind: "array", elements: [] },
        state: "valueOrEnd"
      });
      continue;
    }
    if (token.kind === "}") {
      if (!closeContainer("object")) {
        return null;
      }
      continue;
    }
    if (token.kind === "]") {
      if (!closeContainer("array")) {
        return null;
      }
      continue;
    }
    if (token.kind === ",") {
      if (frame.state !== "commaOrEnd") {
        return null;
      }
      frame.state = frame.kind === "array" ? "valueOrEnd" : "keyOrEnd";
      continue;
    }
    if (token.kind === ":") {
      if (frame.kind !== "object" || frame.state !== "colon") {
        return null;
      }
      frame.state = "value";
      continue;
    }
    if (frame.kind === "object" && frame.state === "keyOrEnd") {
      let key;
      try {
        key = JSON.parse(token.value);
      } catch {
        return null;
      }
      if (typeof key !== "string") {
        return null;
      }
      frame.pendingKey = key;
      frame.pendingKeyToken = token;
      frame.state = "colon";
      continue;
    }
    if (!canAcceptValue(frame)) {
      return null;
    }
    attachValue({ kind: "value", token });
  }
  if (stack.length !== 1 || root.state !== "done") {
    return null;
  }
  return root.value;
}

function orderedJSONTokens(tokens) {
  const root = parseJSONTokens(tokens);
  if (!root) {
    return tokens;
  }
  const result = [];
  const work = [{ kind: "node", node: root }];
  const pushToken = value => work.push({ kind: "token", token: { kind: value, value } });
  while (work.length > 0) {
    const operation = work.pop();
    if (operation.kind === "token") {
      result.push(operation.token);
      continue;
    }
    const node = operation.node;
    if (node.kind === "value") {
      result.push(node.token);
      continue;
    }
    if (node.kind === "array") {
      pushToken("]");
      for (let index = node.elements.length - 1; index >= 0; index -= 1) {
        work.push({ kind: "node", node: node.elements[index] });
        if (index > 0) {
          pushToken(",");
        }
      }
      pushToken("[");
      continue;
    }
    const members = node.members.sort((left, right) => {
      const keyOrder = compareJSONKeys(left.key, right.key);
      return keyOrder !== 0 ? keyOrder : left.index - right.index;
    });
    pushToken("}");
    for (let index = members.length - 1; index >= 0; index -= 1) {
      const member = members[index];
      work.push({ kind: "node", node: member.value });
      pushToken(":");
      work.push({ kind: "token", token: member.keyToken });
      if (index > 0) {
        pushToken(",");
      }
    }
    pushToken("{");
  }
  return result;
}

export function formatJSON(value, jsonKeyOrder = "preserve") {
  try {
    JSON.parse(value);
  } catch {
    return { available: false, text: value, diagnostic: "JSON syntax is incomplete or invalid." };
  }
  const tokens = tokenizeJSON(value);
  if (!tokens) {
    return { available: false, text: value, diagnostic: "JSON string syntax is incomplete." };
  }
  const orderedTokens = jsonKeyOrder === "sorted" ? orderedJSONTokens(tokens) : tokens;
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
  for (let index = 0; index < orderedTokens.length; index += 1) {
    const token = orderedTokens[index];
    const next = orderedTokens[index + 1]?.kind;
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

function rgbaColor(color) {
  return `rgb(${color.red * 100}% ${color.green * 100}% ${color.blue * 100}% / ${color.alpha})`;
}

function validRGBA(value) {
  if (!value || typeof value !== "object") {
    return null;
  }
  const components = [value.red, value.green, value.blue, value.alpha];
  if (!components.every(component => Number.isFinite(component) && component >= 0 && component <= 1)) {
    return null;
  }
  return {
    red: value.red,
    green: value.green,
    blue: value.blue,
    alpha: value.alpha
  };
}

function validTheme(value) {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value !== "object") {
    return null;
  }
  const theme = {
    background: validRGBA(value.background),
    foreground: validRGBA(value.foreground),
    gutterBackground: validRGBA(value.gutterBackground),
    gutterForeground: validRGBA(value.gutterForeground),
    border: validRGBA(value.border),
    caret: validRGBA(value.caret),
    activeLineFill: validRGBA(value.activeLineFill)
  };
  return Object.values(theme).every(Boolean) ? theme : null;
}

function customTheme(colorScheme, theme) {
  const background = rgbaColor(theme.background);
  const foreground = rgbaColor(theme.foreground);
  const gutterBackground = rgbaColor(theme.gutterBackground);
  const gutterForeground = rgbaColor(theme.gutterForeground);
  const border = rgbaColor(theme.border);
  const caret = rgbaColor(theme.caret);
  const activeLineFill = rgbaColor(theme.activeLineFill);
  return EditorView.theme({
    "&": {
      colorScheme,
      backgroundColor: background,
      color: foreground,
      border: `1px solid ${border}`
    },
    ".cm-content": {
      color: foreground,
      caretColor: caret
    },
    ".cm-cursor, .cm-dropCursor": {
      borderLeftColor: caret
    },
    ".cm-gutters": {
      backgroundColor: gutterBackground,
      color: gutterForeground,
      border: "none",
      borderRight: `1px solid ${border}`
    },
    ".cm-activeLine, .cm-activeLineGutter": {
      backgroundColor: activeLineFill
    }
  });
}

function lightTheme(increaseContrast, theme = null) {
  if (theme) {
    return customTheme("light", theme);
  }
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

function darkTheme(increaseContrast, theme = null) {
  if (theme) {
    return [customTheme("dark", theme), oneDark];
  }
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
      appearance: { colorScheme: "light", increaseContrast: false, reduceMotion: false, reduceTransparency: false, theme: null },
      editorName: "Code editor",
      diagnosticPresentationPolicy: null,
      jsonKeyOrder: "preserve"
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
    this.heightPolicy = { mode: "fillsAvailableScrollViewport", minimumVisibleRows: 0 };
    this.heightMeasurementFrame = null;
    this.heightMeasurementGeneration = 0;
    this.heightObserver = null;
    this.lastObservedWidth = null;
    this.lastReportedHeight = null;
    this.heightMeasurementID = null;
    this.languageCompartment = new Compartment();
    this.appearanceCompartment = new Compartment();
    this.lineNumberCompartment = new Compartment();
    this.readOnlyCompartment = new Compartment();
    this.lineWrappingCompartment = new Compartment();
    this.foldCompartment = new Compartment();
    this.listenerCompartment = new Compartment();
    this.handlers = [];
    this.focusHandlers = [];
    this.commandContextHandlers = [];
    this.commandContextTimer = null;
    this.commandContextForcePending = false;
    this.commandContextSequence = 0;
    this.reportedCommandContext = null;
    this.reportedCommandContextRevision = null;
    this.findContextID = null;
    this.findFocusActive = false;
    this.findInput = null;
    this.findHistory = null;
    this.findCompositionSettlementTimer = null;
    this.findBeforeInputExpiryTimer = null;
    this.contextObserver = null;
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
    this.installFocusHandlers();
    this.installCommandContextHandlers();
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
      if (this.replaceHeightMeasurement(command.measurementID)) {
        this.configure(command);
      }
      break;
    case "updateConfiguration":
      if (this.replaceHeightMeasurement(command.measurementID)) {
        this.updateConfiguration(command.configuration);
      }
      break;
    case "setHeightPolicy":
      if (this.replaceHeightMeasurement(command.measurementID)) {
        this.updateHeightPolicy(command.policy);
      }
      break;
    case "apply":
      this.applySnapshot(command, true);
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
        this.resetFindHistoryForPanelReopen();
        this.scheduleCommandContextReport(true);
      }
      break;
    case "routeCommand":
      this.routeCommand(command);
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

  replaceHeightMeasurement(measurementID) {
    if (!isValidMeasurementID(measurementID)) {
      this.post({ type: "failure", code: "transportFailure" });
      return false;
    }
    this.resetHeightMeasurement();
    this.heightMeasurementID = measurementID;
    return true;
  }

  configure(command) {
    this.resetHeightMeasurement();
    this.heightPolicy = { mode: "fillsAvailableScrollViewport", minimumVisibleRows: 0 };
    this.initializing = true;
    this.configured = false;
    this.sessionID = command.sessionID;
    this.replicaID = command.replicaID;
    this.loadID = command.loadID;
    this.hostText = command.text;
    this.hostRevision = Number(command.revision);
    this.localRevision = this.hostRevision;
    this.configuration = command.configuration;
    this.commandContextSequence = 0;
    this.reportedCommandContext = null;
    this.reportedCommandContextRevision = null;
    this.retireFindHistory();
    this.updateConfiguration(this.configuration);
    this.replaceDocument(command.text, command.selections, true);
    this.localEditBeforeConfiguration = false;
    this.initializing = false;
    this.configured = true;
    this.updateConfiguration(this.configuration);
    this.scheduleDiagnostics();
    this.post({ type: "configured" });
    this.scheduleCommandContextReport(true);
  }

  updateHeightPolicy(value) {
    this.resetHeightMeasurement();
    this.heightPolicy = normalizedHeightPolicy(value);
    if (this.configured) {
      if (this.heightPolicy.mode === "contentSized") {
        this.installHeightObserver();
        this.scheduleHeightMeasurement();
      } else if (this.heightPolicy.minimumVisibleRows > 0) {
        this.installFillHeightObserver();
        this.scheduleHeightMeasurement();
      }
    }
  }

  resetHeightMeasurement() {
    this.cancelHeightMeasurement();
    this.disconnectHeightObserver();
    this.heightMeasurementGeneration += 1;
    this.lastObservedWidth = null;
    this.lastReportedHeight = null;
  }

  cancelHeightMeasurement() {
    if (this.heightMeasurementFrame === null) {
      return;
    }
    const cancel = this.documentRef.defaultView?.cancelAnimationFrame ?? globalThis.cancelAnimationFrame;
    if (typeof cancel === "function") {
      cancel(this.heightMeasurementFrame);
    }
    this.heightMeasurementFrame = null;
  }

  disconnectHeightObserver() {
    this.heightObserver?.disconnect?.();
    this.heightObserver = null;
  }

  installHeightObserver() {
    if (this.heightObserver || !this.view?.dom) {
      return;
    }
    const Observer = this.documentRef.defaultView?.ResizeObserver ?? globalThis.ResizeObserver;
    if (typeof Observer !== "function") {
      return;
    }
    this.heightObserver = new Observer(entries => {
      const width = Number(entries?.[0]?.contentRect?.width);
      if (!Number.isFinite(width) || width === this.lastObservedWidth) {
        return;
      }
      this.lastObservedWidth = width;
      this.scheduleHeightMeasurement();
    });
    this.heightObserver.observe(this.view.dom);
  }

  installFillHeightObserver() {
    if (this.heightObserver || !this.diagnosticsPanel) {
      return;
    }
    const Observer = this.documentRef.defaultView?.ResizeObserver ?? globalThis.ResizeObserver;
    if (typeof Observer !== "function") {
      return;
    }
    this.heightObserver = new Observer(entries => {
      const width = Number(entries?.[0]?.contentRect?.width);
      if (!Number.isFinite(width) || width === this.lastObservedWidth) {
        return;
      }
      this.lastObservedWidth = width;
      this.scheduleHeightMeasurement();
    });
    this.heightObserver.observe(this.diagnosticsPanel);
  }

  scheduleHeightMeasurement() {
    const positiveFill = this.heightPolicy.mode === "fillsAvailableScrollViewport"
      && this.heightPolicy.minimumVisibleRows > 0;
    if (!this.configured || (!positiveFill && this.heightPolicy.mode !== "contentSized")
      || !this.view || this.heightMeasurementFrame !== null) {
      return;
    }
    const request = this.documentRef.defaultView?.requestAnimationFrame
      ?? globalThis.requestAnimationFrame;
    if (typeof request !== "function") {
      return;
    }
    const generation = this.heightMeasurementGeneration;
    const frame = request(() => {
      if (generation !== this.heightMeasurementGeneration) {
        return;
      }
      this.heightMeasurementFrame = null;
      this.measureHeight();
    });
    this.heightMeasurementFrame = frame ?? 0;
  }

  measureHeight() {
    if (!this.configured || !this.view) {
      return;
    }
    if (!this.heightMeasurementID) {
      return;
    }
    const lineHeight = Number(this.view.defaultLineHeight);
    const paddingTop = Number(this.view.documentPadding?.top);
    const paddingBottom = Number(this.view.documentPadding?.bottom);
    const documentPadding = paddingTop + paddingBottom;
    if (!Number.isFinite(lineHeight) || lineHeight <= 0
      || !Number.isFinite(paddingTop) || paddingTop < 0
      || !Number.isFinite(paddingBottom) || paddingBottom < 0
      || !Number.isFinite(documentPadding) || documentPadding < 0) {
      return;
    }
    let totalHeight;
    if (this.heightPolicy.mode === "contentSized") {
      const editor = this.view.dom;
      const scrollDOM = this.view.scrollDOM;
      if (!editor || !scrollDOM) {
        return;
      }
      const minimumHeight = this.heightPolicy.minimumVisibleRows * lineHeight + documentPadding;
      const maximumHeight = this.heightPolicy.maximumVisibleRows * lineHeight + documentPadding;
      if (!Number.isFinite(minimumHeight) || !Number.isFinite(maximumHeight)
        || minimumHeight < 0 || maximumHeight < minimumHeight) {
        return;
      }
      const naturalHeight = withNaturalEditorHeight(
        editor, scrollDOM, () => Number(scrollDOM.scrollHeight));
      if (!Number.isFinite(naturalHeight) || naturalHeight < 0) {
        return;
      }
      const editorHeight = Math.max(minimumHeight, Math.min(maximumHeight, naturalHeight));
      totalHeight = editorHeight + this.renderedDiagnosticsHeight();
    } else {
      const minimumHeight = this.heightPolicy.minimumVisibleRows * lineHeight + documentPadding;
      if (!Number.isFinite(minimumHeight) || minimumHeight < 0) {
        return;
      }
      const diagnosticsHeight = this.positiveFillDiagnosticsHeight();
      if (diagnosticsHeight === null) {
        return;
      }
      totalHeight = minimumHeight + diagnosticsHeight;
    }
    if (!Number.isFinite(totalHeight) || totalHeight < 0 || totalHeight > MAX_REPORTED_HEIGHT) {
      return;
    }
    if (totalHeight === this.lastReportedHeight) {
      return;
    }
    this.lastReportedHeight = totalHeight;
    this.post({
      type: "contentSize",
      measurementID: this.heightMeasurementID,
      height: totalHeight
    });
  }

  renderedDiagnosticsHeight() {
    if (!this.diagnosticsPanel || this.diagnosticsPanel.hidden) {
      return 0;
    }
    const rect = this.diagnosticsPanel.getBoundingClientRect?.();
    const height = Number(rect?.height ?? this.diagnosticsPanel.offsetHeight);
    return Number.isFinite(height) && height >= 0 ? height : 0;
  }

  positiveFillDiagnosticsHeight() {
    if (!this.diagnosticsPanel || this.diagnosticsPanel.hidden) {
      return 0;
    }
    const panel = this.diagnosticsPanel;
    const style = this.documentRef.defaultView?.getComputedStyle?.(panel);
    const finiteNumber = value => {
      const result = Number.parseFloat(value);
      return Number.isFinite(result) && result >= 0 ? result : null;
    };
    const naturalHeight = Number(panel.scrollHeight);
    const borderTop = finiteNumber(style?.borderTopWidth);
    const borderBottom = finiteNumber(style?.borderBottomWidth);
    const maxHeight = finiteNumber(style?.maxHeight);
    if (!Number.isFinite(naturalHeight) || naturalHeight < 0
      || borderTop === null || borderBottom === null || maxHeight === null) {
      return null;
    }
    const measuredHeight = naturalHeight + borderTop + borderBottom;
    if (!Number.isFinite(measuredHeight) || measuredHeight < 0) {
      return null;
    }
    return Math.min(measuredHeight, maxHeight);
  }

  updateConfiguration(configuration) {
    if (!configuration) {
      return;
    }
    this.configuration = {
      ...this.configuration,
      ...configuration,
      jsonKeyOrder: configuration.jsonKeyOrder ?? "preserve",
      appearance: {
        ...this.configuration.appearance,
        ...(configuration.appearance || {})
      }
    };
    this.configuration.appearance.theme = validTheme(this.configuration.appearance.theme);
    if (!this.view) {
      return;
    }
    const text = this.view.state.doc.toString();
    const appearance = this.configuration.appearance;
    const theme = validTheme(appearance.theme);
    this.view.dispatch({
      effects: [
        this.languageCompartment.reconfigure(languageExtension(this.configuration.language, text)),
        this.appearanceCompartment.reconfigure(appearance.colorScheme === "dark" ? darkTheme(appearance.increaseContrast, theme) : lightTheme(appearance.increaseContrast, theme)),
        this.lineNumberCompartment.reconfigure(this.configuration.showsLineNumbers ? lineNumbers() : []),
        this.readOnlyCompartment.reconfigure(this.initializing || this.configuration.isReadOnly ? EditorState.readOnly.of(true) : []),
        this.lineWrappingCompartment.reconfigure(this.configuration.wrapsLines ? EditorView.lineWrapping : []),
        this.foldCompartment.reconfigure(this.configuration.showsLineNumbers ? foldGutter() : [])
      ]
    });
    const name = this.configuration.editorName || "Code editor";
    const colorScheme = this.configuration.appearance.colorScheme;
    const cssColorScheme = colorScheme === "dark" || colorScheme === "light" ? colorScheme : "light dark";
    this.documentRef.documentElement?.style?.setProperty("color-scheme", cssColorScheme);
    this.documentRef.body?.style?.setProperty("color-scheme", cssColorScheme);
    this.documentRef.body?.classList?.toggle(
      "cm-host-reduce-transparency",
      Boolean(this.configuration.appearance.reduceTransparency)
    );
    this.view.dom.setAttribute("aria-label", name);
    this.view.dom.setAttribute("role", "textbox");
    this.view.dom.setAttribute("spellcheck", "false");
    this.view.dom.setAttribute("aria-busy", this.initializing ? "true" : "false");
    this.view.dom.setAttribute("aria-readonly", (this.initializing || this.configuration.isReadOnly) ? "true" : "false");
    this.view.dom.style.setProperty("font-family", "ui-monospace, SFMono-Regular, Menlo, monospace");
    this.view.dom.style.setProperty("transition", this.configuration.appearance.reduceMotion ? "none" : "opacity 120ms ease");
    if (theme) {
      this.view.dom.style.removeProperty?.("background");
    } else {
      this.view.dom.style.setProperty("background", appearance.reduceTransparency ? "Canvas" : "transparent");
    }
    this.scheduleDiagnostics();
    this.scheduleHeightMeasurement();
    this.scheduleCommandContextReport();
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
    const diagnostics = presentedDiagnostics(this.configuration.language, text, this.configuration);
    this.view.dispatch(setDiagnostics(this.view.state, diagnostics));
    if (!this.diagnosticsPanel) {
      this.scheduleHeightMeasurement();
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
    this.scheduleHeightMeasurement();
  }

  handleUpdate(update) {
    if (!update.docChanged) {
      if (update.selectionSet && this.configured && !this.applyingHostChange && !this.deferredLocalSync) {
        this.post({ type: "selection", revision: this.localRevision, selection: selectionValue(update.state.selection.main) });
      }
      return;
    }
    this.scheduleDiagnostics();
    this.scheduleHeightMeasurement();
    if (this.applyingHostChange) {
      this.scheduleCommandContextReport();
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
    this.scheduleCommandContextReport();
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
    this.scheduleCommandContextReport();
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
    this.retireFindHistory();
    this.replaceDocument(command.text, command.selections, true);
    this.hostText = command.text;
    this.hostRevision = Number(command.revision);
    this.localRevision = this.hostRevision;
    this.pendingAcks.clear();
    this.pendingTransactions = [];
    this.deferredLocalSync = false;
    this.divergent = false;
    this.scheduleDiagnostics();
    this.scheduleCommandContextReport(true);
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

  routeCommand(command) {
    const commandName = command?.command;
    const requestID = command?.requestID;
    const expectedRevision = Number(command?.expectedRevision);
    const expectation = command?.expectation === "find"
      ? { scope: "find", contextID: command.findContextID }
      : command?.expectation === "contentOrCurrentFind"
        ? { scope: "contentOrCurrentFind", contextID: null }
        : null;
    let result = "unavailable";
    if (requestID && (commandName === "undo" || commandName === "redo")
      && Number.isInteger(expectedRevision) && expectedRevision === this.localRevision
      && expectation) {
      if (expectation.scope === "find") {
        const input = this.exactFindInput();
        if (input && expectation.contextID === this.ensureFindContext(input)) {
          result = this.performFindHistory(commandName, input, expectation.contextID)
            ? "handledByEmbeddedControl" : "unavailable";
        }
      } else {
        const input = this.exactFindInput();
        if (input) {
          result = this.performFindHistory(commandName, input, this.ensureFindContext(input))
            ? "handledByEmbeddedControl" : "unavailable";
        } else if (this.isContentFocused()) {
          result = "forwardedToHost";
        }
      }
    }
    this.post({
      type: "commandRouteResult",
      requestID,
      revision: this.localRevision,
      command: commandName,
      expectation: expectation?.scope,
      findContextID: expectation?.contextID ?? null,
      result
    });
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
    const result = formatJSON(text, this.configuration.jsonKeyOrder);
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
    if (!this.flushRequests.has(requestID) && this.flushRequests.size >= MAX_PENDING_FLUSH_REQUESTS) {
      this.post({ type: "flushResult", requestID, success: false, code: "timeout" });
      return;
    }
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
      this.scheduleCommandContextReport(true);
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
      this.scheduleCommandContextReport(true);
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
      this.scheduleCommandContextReport(true);
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

  installFocusHandlers() {
    if (!this.documentRef?.addEventListener) {
      return;
    }
    const focusIn = event => {
      const input = this.exactFindInput();
      if (input && event.target === input) {
        this.ensureFindContext(input, !this.findFocusActive && this.findInput === input);
        this.findFocusActive = true;
      }
      this.scheduleCommandContextReport(true);
    };
    const focusOut = event => {
      if (event.target === this.findInput) {
        this.retireFindHistory();
      }
      this.scheduleCommandContextReport(true);
    };
    this.documentRef.addEventListener("focusin", focusIn, true);
    this.documentRef.addEventListener("focusout", focusOut, true);
    this.focusHandlers = [
      ["focusin", focusIn],
      ["focusout", focusOut]
    ];
  }

  installCommandContextHandlers() {
    if (!this.documentRef?.addEventListener) {
      return;
    }
    const beforeInput = event => {
      const input = this.findInputElement();
      if (!input || event.target !== input || this.documentRef.activeElement !== input) {
        return;
      }
      const contextID = this.ensureFindContext(input);
      if (event.inputType === "historyUndo" || event.inputType === "historyRedo") {
        event.preventDefault?.();
        event.stopImmediatePropagation?.();
        this.performFindHistory(
          event.inputType === "historyUndo" ? "undo" : "redo",
          input,
          contextID
        );
        return;
      }
      if (this.findHistory?.applying) {
        return;
      }
      this.clearFindBeforeInput();
      if (event.isTrusted !== true || event.defaultPrevented) {
        return;
      }
      this.synchronizeFindHistory(input);
      this.captureFindBeforeInput(event.inputType);
      this.scheduleCommandContextReport(true);
    };
    const input = event => {
      const findInput = this.findInputElement();
      if (!findInput || event.target !== findInput) {
        return;
      }
      this.handleFindInput(findInput, event);
    };
    const selectionChange = () => {
      const findInput = this.exactFindInput();
      if (!findInput) {
        return;
      }
      const history = this.findHistory;
      if (!history || history.applying || history.compositionActive || history.compositionEnding) {
        return;
      }
      this.synchronizeFindHistory(findInput);
      this.scheduleCommandContextReport(true);
    };
    const keydown = event => {
      const findInput = this.exactFindInput();
      if (!findInput || event.target !== findInput || this.documentRef.activeElement !== findInput
        || !event.metaKey || event.ctrlKey || event.altKey
        || String(event.key).toLowerCase() !== "z") {
        return;
      }
      const command = event.shiftKey ? "redo" : "undo";
      const contextID = this.ensureFindContext(findInput);
      event.preventDefault?.();
      event.stopImmediatePropagation?.();
      this.performFindHistory(command, findInput, contextID);
    };
    const compositionStart = event => {
      const findInput = this.findInputElement();
      if (!findInput || event.target !== findInput || this.documentRef.activeElement !== findInput) {
        return;
      }
      this.ensureFindContext(findInput);
      this.synchronizeFindHistory(findInput);
      const history = this.findHistory;
      if (!history || history.applying) {
        return;
      }
      this.cancelFindCompositionSettlement();
      history.compositionGeneration += 1;
      history.compositionStart = history.current;
      history.compositionActive = true;
      history.compositionEnding = false;
      history.compositionCancelled = false;
      history.compositionAbandoned = history.oversized;
      this.clearFindBeforeInput();
      this.scheduleCommandContextReport(true);
    };
    const compositionEnd = event => {
      const findInput = this.findInputElement();
      if (!findInput || event.target !== findInput || !this.findHistory?.compositionActive) {
        return;
      }
      this.findHistory.compositionActive = false;
      this.findHistory.compositionEnding = true;
      this.scheduleFindCompositionSettlement(findInput);
      this.scheduleCommandContextReport(true);
    };
    const compositionCancel = event => {
      const findInput = this.findInputElement();
      if (!findInput || event.target !== findInput || !this.findHistory?.compositionActive) {
        return;
      }
      this.findHistory.compositionActive = false;
      this.findHistory.compositionEnding = true;
      this.findHistory.compositionCancelled = true;
      this.clearFindBeforeInput();
      this.scheduleFindCompositionSettlement(findInput);
      this.scheduleCommandContextReport(true);
    };
    this.documentRef.addEventListener("input", input, true);
    this.documentRef.addEventListener("beforeinput", beforeInput, true);
    this.documentRef.addEventListener("selectionchange", selectionChange, true);
    this.documentRef.addEventListener("keydown", keydown, true);
    this.documentRef.addEventListener("compositionstart", compositionStart, true);
    this.documentRef.addEventListener("compositionend", compositionEnd, true);
    this.documentRef.addEventListener("compositioncancel", compositionCancel, true);
    this.commandContextHandlers = [
      ["input", input],
      ["beforeinput", beforeInput],
      ["selectionchange", selectionChange],
      ["keydown", keydown],
      ["compositionstart", compositionStart],
      ["compositionend", compositionEnd],
      ["compositioncancel", compositionCancel]
    ];
    if (this.documentRef.defaultView?.MutationObserver && this.documentRef.body) {
      this.contextObserver = new this.documentRef.defaultView.MutationObserver(() => {
        const input = this.findInputElement();
        if (input !== this.findInput) {
          if (input) {
            this.ensureFindContext(input);
          } else {
            this.retireFindHistory();
          }
        }
        this.scheduleCommandContextReport(true);
      });
      this.contextObserver.observe(this.documentRef.body, { childList: true, subtree: true });
    }
  }

  findInputElement() {
    return this.documentRef?.querySelector?.(".cm-search input") ?? null;
  }

  exactFindInput() {
    const input = this.findInputElement();
    return input && this.documentRef?.activeElement === input ? input : null;
  }

  resetFindHistoryForPanelReopen() {
    const input = this.findInputElement();
    if (!input) {
      this.retireFindHistory();
      return;
    }
    this.resetFindHistory(input, this.findSnapshot(input));
    this.findFocusActive = this.documentRef.activeElement === input;
  }

  ensureFindContext(input, resetExisting = false) {
    if (this.findInput !== input || !this.findContextID || resetExisting || !this.findHistory) {
      this.resetFindHistory(input, this.findSnapshot(input));
    }
    return this.findContextID;
  }

  makeFindHistory(snapshot) {
    const oversized = snapshot.value.length > MAX_FIND_HISTORY_UNITS;
    return {
      current: oversized ? null : snapshot,
      undo: [],
      redo: [],
      pendingBeforeInput: null,
      pendingGeneration: 0,
      compositionStart: null,
      compositionGeneration: 0,
      compositionActive: false,
      compositionEnding: false,
      compositionCancelled: false,
      compositionAbandoned: false,
      applying: false,
      oversized
    };
  }

  resetFindHistory(input, snapshot) {
    this.clearFindBeforeInput();
    this.cancelFindCompositionSettlement();
    this.findInput = input;
    this.findContextID = crypto.randomUUID();
    this.findHistory = this.makeFindHistory(snapshot);
  }

  retireFindHistory() {
    this.clearFindBeforeInput();
    this.cancelFindCompositionSettlement();
    this.findContextID = null;
    this.findFocusActive = false;
    this.findInput = null;
    this.findHistory = null;
  }

  cancelFindCompositionSettlement() {
    if (this.findCompositionSettlementTimer !== null) {
      clearTimeout(this.findCompositionSettlementTimer);
      this.findCompositionSettlementTimer = null;
    }
  }

  findSnapshot(input) {
    const value = String(input?.value ?? "");
    const selectionStart = Number.isInteger(input?.selectionStart)
      ? Math.max(0, Math.min(value.length, input.selectionStart))
      : value.length;
    const selectionEnd = Number.isInteger(input?.selectionEnd)
      ? Math.max(selectionStart, Math.min(value.length, input.selectionEnd))
      : selectionStart;
    return {
      value,
      selectionStart,
      selectionEnd,
      selectionDirection: input?.selectionDirection === "backward" ? "backward" : "forward"
    };
  }

  sameFindSnapshot(first, second) {
    return Boolean(first && second) && first.value === second.value
      && first.selectionStart === second.selectionStart
      && first.selectionEnd === second.selectionEnd
      && first.selectionDirection === second.selectionDirection;
  }

  findHistoryUnits(history, current = history.current) {
    const snapshots = new Set([
      current, ...history.undo, ...history.redo,
      history.pendingBeforeInput?.before, history.compositionStart
    ]);
    let units = 0;
    for (const snapshot of snapshots) {
      units += snapshot?.value.length ?? 0;
    }
    return units;
  }

  trimFindHistory(history, current = history.current) {
    const bounded = current && current.value.length <= MAX_FIND_HISTORY_UNITS ? current : null;
    if (!bounded) {
      this.abandonFindComposition(history);
    }
    while (history.undo.length + history.redo.length > MAX_FIND_HISTORY_SNAPSHOTS
      || this.findHistoryUnits(history, bounded) > MAX_FIND_HISTORY_UNITS) {
      if (history.undo.length > 0) {
        history.undo.shift();
      } else if (history.redo.length > 0) {
        history.redo.shift();
      } else {
        break;
      }
    }
    if (this.findHistoryUnits(history, bounded) > MAX_FIND_HISTORY_UNITS) {
      this.clearFindBeforeInput();
    }
    if (this.findHistoryUnits(history, bounded) > MAX_FIND_HISTORY_UNITS) {
      this.abandonFindComposition(history);
    }
    history.current = bounded;
    history.oversized = !bounded;
  }

  abandonFindComposition(history) {
    history.undo = [];
    history.redo = [];
    this.clearFindBeforeInput();
    history.compositionStart = null;
    history.compositionAbandoned = true;
  }

  synchronizeFindHistory(input) {
    const history = this.findHistory;
    const live = this.findSnapshot(input);
    if (this.sameFindSnapshot(history.current, live)) {
      return;
    }
    if (live.value !== history.current?.value) {
      if (!history.compositionActive && !history.compositionEnding) {
        this.resetFindHistory(input, live);
        return;
      }
      this.abandonFindComposition(history);
    }
    this.trimFindHistory(history, live);
  }

  captureFindBeforeInput(inputType) {
    this.clearFindBeforeInput();
    const history = this.findHistory;
    if (!history.current) {
      return;
    }
    const contextID = this.findContextID;
    const generation = ++history.pendingGeneration;
    history.pendingBeforeInput = {
      contextID,
      generation,
      inputType: String(inputType || ""),
      before: history.current
    };
    this.expireFindBeforeInput(contextID, generation);
  }

  expireFindBeforeInput(contextID, generation) {
    const timer = setTimeout(() => {
      if (this.findBeforeInputExpiryTimer !== timer) {
        return;
      }
      this.findBeforeInputExpiryTimer = null;
      const history = this.findHistory;
      const pending = history?.pendingBeforeInput;
      if (this.findContextID === contextID
        && pending?.contextID === contextID
        && pending?.generation === generation
        && history.pendingGeneration === generation) {
        history.pendingBeforeInput = null;
      }
    }, 0);
    this.findBeforeInputExpiryTimer = timer;
  }

  clearFindBeforeInput() {
    if (this.findBeforeInputExpiryTimer !== null) {
      clearTimeout(this.findBeforeInputExpiryTimer);
      this.findBeforeInputExpiryTimer = null;
    }
    if (this.findHistory) {
      this.findHistory.pendingBeforeInput = null;
    }
  }

  recordFindInputTransition(input, before, after) {
    const history = this.findHistory;
    if (!history || history.applying) {
      return;
    }
    if (after.value.length > MAX_FIND_HISTORY_UNITS || before.value.length > MAX_FIND_HISTORY_UNITS) {
      this.resetFindHistory(input, after);
      this.findHistory.oversized = true;
      return;
    }
    history.undo.push(before);
    history.redo = [];
    this.trimFindHistory(history, after);
  }

  handleFindInput(input, event) {
    if (this.findInput !== input || !this.findContextID) {
      this.ensureFindContext(input);
    }
    const history = this.findHistory;
    if (!history) {
      return;
    }
    const after = this.findSnapshot(input);
    if (history.applying) {
      this.scheduleCommandContextReport(true);
      return;
    }
    const pending = history.pendingBeforeInput;
    this.clearFindBeforeInput();
    const paired = event?.isTrusted === true
      && pending?.contextID === this.findContextID
      && pending?.generation === history.pendingGeneration
      && pending?.inputType === String(event.inputType || "")
      && this.sameFindSnapshot(pending?.before, history.current);
    if (history.compositionActive || history.compositionEnding) {
      if (!paired) {
        this.abandonFindComposition(history);
      }
      this.trimFindHistory(history, after);
    } else if (!paired) {
      this.resetFindHistory(input, after);
    } else if (!this.sameFindSnapshot(pending.before, after)) {
      this.recordFindInputTransition(input, pending.before, after);
    } else {
      this.trimFindHistory(history, after);
    }
    this.scheduleCommandContextReport(true);
  }

  scheduleFindCompositionSettlement(input) {
    this.cancelFindCompositionSettlement();
    const contextID = this.findContextID;
    const generation = this.findHistory.compositionGeneration;
    const timer = setTimeout(() => {
      if (this.findCompositionSettlementTimer !== timer) {
        return;
      }
      this.findCompositionSettlementTimer = null;
      const history = this.findHistory;
      if (!history || this.findInput !== input || this.findContextID !== contextID
        || history.compositionGeneration !== generation || !history.compositionEnding) {
        return;
      }
      const after = this.findSnapshot(input);
      const before = history.compositionStart;
      const cancelled = history.compositionCancelled;
      history.compositionStart = null;
      history.compositionEnding = false;
      history.compositionCancelled = false;
      this.clearFindBeforeInput();
      if (history.compositionAbandoned) {
        this.resetFindHistory(input, after);
      } else if (cancelled && before) {
        this.applyFindSnapshot(input, before, contextID);
      } else if (before && !this.sameFindSnapshot(before, after)) {
        this.recordFindInputTransition(input, before, after);
      } else {
        this.trimFindHistory(history, after);
      }
      this.scheduleCommandContextReport(true);
    }, 0);
    this.findCompositionSettlementTimer = timer;
  }

  isContentFocused() {
    const activeElement = this.documentRef?.activeElement;
    const content = this.view?.contentDOM ?? this.view?.dom?.querySelector?.(".cm-content");
    return Boolean(activeElement && content && activeElement === content);
  }

  findCommandAvailability(command) {
    const input = this.exactFindInput();
    const history = this.findHistory;
    if (!input || !history || history.oversized || history.compositionActive || history.compositionEnding) {
      return { isSupported: false, isEnabled: false };
    }
    return {
      isSupported: true,
      isEnabled: command === "undo" ? history.undo.length > 0 : history.redo.length > 0
    };
  }

  currentCommandContext() {
    const input = this.exactFindInput();
    if (input) {
      const contextID = this.ensureFindContext(input);
      const undo = this.findCommandAvailability("undo");
      const redo = this.findCommandAvailability("redo");
      return {
        scope: "find",
        findContextID: contextID,
        undoSupported: undo.isSupported,
        undoEnabled: undo.isEnabled,
        redoSupported: redo.isSupported,
        redoEnabled: redo.isEnabled
      };
    }
    if (this.isContentFocused()) {
      return {
        scope: "content",
        findContextID: null,
        undoSupported: false,
        undoEnabled: false,
        redoSupported: false,
        redoEnabled: false
      };
    }
    return {
      scope: "unavailable",
      findContextID: null,
      undoSupported: false,
      undoEnabled: false,
      redoSupported: false,
      redoEnabled: false
    };
  }

  scheduleCommandContextReport(force = false) {
    this.commandContextForcePending ||= force;
    if (this.commandContextTimer !== null) {
      return;
    }
    this.commandContextTimer = Promise.resolve().then(() => {
      this.commandContextTimer = null;
      const shouldForce = this.commandContextForcePending;
      this.commandContextForcePending = false;
      this.reportCommandContext(shouldForce);
    });
  }

  reportCommandContext(force = false) {
    if (!this.configured || !this.sessionID || !this.replicaID || !this.loadID) {
      return;
    }
    const context = this.currentCommandContext();
    const revision = this.localRevision;
    const signature = JSON.stringify(context);
    if (!force && signature === this.reportedCommandContext
      && revision === this.reportedCommandContextRevision) {
      return;
    }
    this.reportedCommandContext = signature;
    this.reportedCommandContextRevision = revision;
    this.commandContextSequence += 1;
    this.post({
      type: "commandContext",
      revision,
      contextSequence: this.commandContextSequence,
      commandScope: context.scope,
      findContextID: context.findContextID,
      undoSupported: context.undoSupported,
      undoEnabled: context.undoEnabled,
      redoSupported: context.redoSupported,
      redoEnabled: context.redoEnabled
    });
  }

  performFindHistory(command, input, contextID) {
    if (!input || this.documentRef.activeElement !== input
      || contextID !== this.ensureFindContext(input)
      || !this.findHistory
      || this.findHistory.oversized
      || this.findHistory.compositionActive
      || this.findHistory.compositionEnding) {
      this.scheduleCommandContextReport(true);
      return false;
    }
    const history = this.findHistory;
    const source = command === "undo" ? history.undo : history.redo;
    const destination = command === "undo" ? history.redo : history.undo;
    if (source.length === 0) {
      this.scheduleCommandContextReport(true);
      return false;
    }
    const current = this.findSnapshot(input);
    if (!this.sameFindSnapshot(current, history.current)) {
      this.resetFindHistory(input, current);
      this.scheduleCommandContextReport(true);
      return false;
    }
    const target = source.pop();
    destination.push(history.current);
    return this.applyFindSnapshot(input, target, contextID);
  }

  applyFindSnapshot(input, target, contextID) {
    const history = this.findHistory;
    if (!history || this.exactFindInput() !== input || contextID !== this.findContextID) {
      return false;
    }
    this.clearFindBeforeInput();
    history.applying = true;
    let applied = false;
    try {
      input.value = target.value;
      input.setSelectionRange(target.selectionStart, target.selectionEnd, target.selectionDirection);
      applied = true;
    } catch {
      applied = false;
    }
    try {
      input.dispatchEvent(new Event("input", { bubbles: true }));
      applied = applied && this.exactFindInput() === input && this.findContextID === contextID
        && this.sameFindSnapshot(this.findSnapshot(input), target);
    } catch {
      applied = false;
    } finally {
      history.applying = false;
    }
    if (this.findContextID === contextID) {
      if (applied) {
        this.trimFindHistory(history, target);
      } else {
        this.resetFindHistory(input, this.findSnapshot(input));
      }
    }
    this.scheduleCommandContextReport(true);
    return applied;
  }

  destroy() {
    this.resetHeightMeasurement();
    if (this.documentRef?.removeEventListener) {
      for (const [name, handler] of this.focusHandlers) {
        this.documentRef.removeEventListener(name, handler, true);
      }
    }
    this.focusHandlers = [];
    this.commandContextTimer = null;
    this.commandContextForcePending = false;
    this.reportedCommandContext = null;
    this.reportedCommandContextRevision = null;
    this.retireFindHistory();
    for (const [name, handler] of this.commandContextHandlers) {
      this.documentRef?.removeEventListener(name, handler, true);
    }
    this.commandContextHandlers = [];
    this.contextObserver?.disconnect?.();
    this.contextObserver = null;
    this.configured = false;
    this.initializing = true;
    this.sessionID = null;
    this.replicaID = null;
    this.loadID = null;
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
    this.heightPolicy = { mode: "fillsAvailableScrollViewport", minimumVisibleRows: 0 };
    this.lastObservedWidth = null;
    this.lastReportedHeight = null;
    this.heightMeasurementID = null;
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
