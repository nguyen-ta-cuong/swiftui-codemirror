import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { EditorState } from "@codemirror/state";
import { EditorController } from "../codemirror.js";

function makeStyle() {
  const values = new Map();
  return {
    getPropertyValue(name) { return values.get(name) ?? ""; },
    setProperty(name, value) { values.set(name, value); },
    removeProperty(name) { values.delete(name); }
  };
}

function makeHeightController() {
  const messages = [];
  const frames = new Map();
  const cancelledFrames = new Map();
  const observers = new Set();
  let nextFrame = 1;
  let panelHeight = 0;
  let panelMaxHeight = "96px";
  let panelBorderTop = "2px";
  let panelBorderBottom = "2px";
  const panel = {
    hidden: true,
    textContent: "",
    scrollHeight: 0,
    classList: { toggle() {} },
    getBoundingClientRect() { return { height: panelHeight }; },
    remove() {}
  };
  const dom = {
    style: makeStyle(),
    setAttribute() {},
    addEventListener() {},
    removeEventListener() {}
  };
  const scrollDOM = { style: makeStyle(), scrollHeight: 120 };
  const state = EditorState.create({ doc: "source" });
  const documentRef = {
    body: null,
    activeElement: null,
    defaultView: {
      requestAnimationFrame(callback) {
        const id = nextFrame++;
        frames.set(id, callback);
        return id;
      },
      getComputedStyle(target) {
        if (target !== panel) return {};
        return {
          borderTopWidth: panelBorderTop,
          borderBottomWidth: panelBorderBottom,
          maxHeight: panelMaxHeight
        };
      },
      cancelAnimationFrame(id) {
        const callback = frames.get(id);
        if (callback) cancelledFrames.set(id, callback);
        frames.delete(id);
      },
      ResizeObserver: class {
        constructor(callback) { this.callback = callback; observers.add(this); }
        observe(target) { this.target = target; }
        disconnect() { observers.delete(this); }
      }
    },
    addEventListener() {},
    removeEventListener() {}
  };
  const controller = new EditorController(message => messages.push(message), documentRef);
  controller.sessionID = "session";
  controller.replicaID = "replica";
  controller.loadID = "load";
  controller.heightMeasurementID = "00000000-0000-4000-8000-000000000001";
  controller.configured = true;
  controller.initializing = false;
  controller.diagnosticsPanel = panel;
  controller.view = {
    state,
    dom,
    scrollDOM,
    documentPadding: { top: 4, bottom: 4 },
    defaultLineHeight: 20,
    dispatch() {},
    destroy() {}
  };
  return {
    controller,
    dom,
    frames,
    cancelledFrames,
    messages,
    observers,
    panel,
    scrollDOM,
    setPanelHeight(value) { panelHeight = value; },
    setPanelMaxHeight(value) { panelMaxHeight = value; },
    setPanelBorders(top, bottom) {
      panelBorderTop = top;
      panelBorderBottom = bottom;
    },
    flushFrame() {
      const callback = frames.values().next().value;
      if (callback) {
        frames.delete(frames.keys().next().value);
        callback(0);
      }
    },
    flushCancelledFrames() {
      for (const [id, callback] of cancelledFrames) {
        cancelledFrames.delete(id);
        callback(0);
      }
    },
    emitWidth(width) {
      for (const observer of observers) {
        observer.callback([{ contentRect: { width } }]);
      }
    }
  };
}

function contentSizes(messages) {
  return messages.filter(message => message.type === "contentSize");
}

const measurementID = "00000000-0000-4000-8000-000000000001";

test("content-sized policy reports bounded natural height and restores temporary styles", () => {
  const harness = makeHeightController();
  const { controller, dom, scrollDOM } = harness;
  dom.style.setProperty("height", "fixed");
  scrollDOM.style.setProperty("overflow-y", "auto");
  controller.updateHeightPolicy({ mode: "contentSized", minimumVisibleRows: 3, maximumVisibleRows: 10 });
  harness.flushFrame();

  assert.equal(contentSizes(harness.messages).at(-1).height, 120);
  assert.equal(contentSizes(harness.messages).at(-1).measurementID, measurementID);
  assert.equal(dom.style.getPropertyValue("height"), "fixed");
  assert.equal(scrollDOM.style.getPropertyValue("overflow-y"), "auto");
  controller.destroy();
});

test("content-sized policy grows, caps, and coalesces width observations", () => {
  const harness = makeHeightController();
  const { controller, scrollDOM } = harness;
  controller.updateHeightPolicy({ mode: "contentSized", minimumVisibleRows: 3, maximumVisibleRows: 10 });
  harness.flushFrame();
  scrollDOM.scrollHeight = 240;
  harness.emitWidth(640);
  harness.emitWidth(640);
  assert.equal(harness.frames.size, 1);
  harness.flushFrame();
  assert.deepEqual(contentSizes(harness.messages).map(message => message.height), [120, 208]);
  assert.deepEqual(contentSizes(harness.messages).map(message => message.measurementID), [
    measurementID,
    measurementID
  ]);
  controller.destroy();
});

test("height commands require identity and discard reports from cancelled frames", () => {
  const harness = makeHeightController();
  const { controller, messages } = harness;
  controller.receive({
    type: "setHeightPolicy",
    measurementID: "not-a-uuid",
    policy: { mode: "contentSized", minimumVisibleRows: 3, maximumVisibleRows: 10 }
  });
  assert.equal(messages.at(-1).code, "transportFailure");
  controller.receive({
    type: "setHeightPolicy",
    policy: { mode: "contentSized", minimumVisibleRows: 3, maximumVisibleRows: 10 }
  });
  assert.equal(messages.at(-1).code, "transportFailure");
  controller.receive({
    type: "updateConfiguration",
    measurementID: "not-a-uuid",
    configuration: { appearance: { colorScheme: "dark" } }
  });
  assert.equal(messages.at(-1).code, "transportFailure");
  controller.receive({
    type: "updateConfiguration",
    configuration: { appearance: { colorScheme: "dark" } }
  });
  assert.equal(messages.at(-1).code, "transportFailure");

  const measurementA = measurementID;
  controller.receive({
    type: "setHeightPolicy",
    measurementID: measurementA,
    policy: { mode: "contentSized", minimumVisibleRows: 3, maximumVisibleRows: 10 }
  });
  assert.equal(harness.frames.size, 1);
  const measurementB = "00000000-0000-4000-8000-000000000002";
  controller.receive({
    type: "setHeightPolicy",
    measurementID: measurementB,
    policy: { mode: "contentSized", minimumVisibleRows: 4, maximumVisibleRows: 10 }
  });
  assert.equal(harness.cancelledFrames.size, 1);
  assert.equal(harness.frames.size, 1);
  harness.flushCancelledFrames();
  assert.equal(controller.heightMeasurementFrame, 2);
  assert.equal(harness.frames.size, 1);
  controller.scheduleHeightMeasurement();
  assert.equal(controller.heightMeasurementFrame, 2);
  assert.equal(harness.frames.size, 1);
  assert.equal(contentSizes(messages).length, 0);
  harness.flushFrame();
  assert.equal(contentSizes(messages).length, 1);
  assert.equal(contentSizes(messages).at(-1).measurementID, measurementB);

  const measurementC = "00000000-0000-4000-8000-000000000003";
  controller.receive({
    type: "setHeightPolicy",
    measurementID: measurementC,
    policy: { mode: "contentSized", minimumVisibleRows: 3, maximumVisibleRows: 10 }
  });
  const measurementD = "00000000-0000-4000-8000-000000000004";
  controller.receive({
    type: "updateConfiguration",
    measurementID: measurementD,
    configuration: { appearance: { colorScheme: "light" } }
  });
  assert.equal(harness.cancelledFrames.size, 1);
  harness.flushCancelledFrames();
  assert.equal(contentSizes(messages).length, 1);
  harness.flushFrame();
  assert.deepEqual(contentSizes(messages).map(message => message.measurementID), [
    measurementB,
    measurementD
  ]);
  controller.destroy();
});

test("content-sized policy includes document padding and rejects invalid padding", () => {
  const harness = makeHeightController();
  const { controller, scrollDOM } = harness;
  scrollDOM.scrollHeight = 20;
  controller.updateHeightPolicy({ mode: "contentSized", minimumVisibleRows: 3, maximumVisibleRows: 10 });
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).at(-1).height, 68);

  controller.view.documentPadding = { top: -1, bottom: 4 };
  controller.scheduleHeightMeasurement();
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).length, 1);
  controller.destroy();
});

test("diagnostic height is added after the bounded editor region", () => {
  const harness = makeHeightController();
  const { controller, panel } = harness;
  panel.hidden = false;
  harness.setPanelHeight(30);
  controller.updateHeightPolicy({ mode: "contentSized", minimumVisibleRows: 3, maximumVisibleRows: 10 });
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).at(-1).height, 150);
  panel.hidden = true;
  controller.scheduleHeightMeasurement();
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).at(-1).height, 120);
  controller.destroy();
});

test("fill and invalid policies perform no height work", () => {
  const harness = makeHeightController();
  const { controller } = harness;
  controller.updateHeightPolicy({ mode: "contentSized", minimumVisibleRows: 4, maximumVisibleRows: 2 });
  assert.equal(controller.heightPolicy.mode, "fillsAvailableScrollViewport");
  assert.equal(harness.observers.size, 0);
  assert.equal(harness.frames.size, 0);
  controller.updateHeightPolicy({ mode: "fillsAvailableScrollViewport" });
  controller.scheduleHeightMeasurement();
  assert.equal(harness.messages.length, 0);
  controller.destroy();
});

test("positive fill measures natural diagnostics, width changes, and zero work", () => {
  const harness = makeHeightController();
  const { controller, panel } = harness;
  controller.updateHeightPolicy({ mode: "fillsAvailableScrollViewport", minimumVisibleRows: 3 });
  assert.equal(harness.observers.size, 1);
  assert.equal([...harness.observers][0].target, panel);
  assert.equal(harness.frames.size, 1);
  harness.flushFrame();
  assert.deepEqual(contentSizes(harness.messages).map(message => message.height), [68]);

  panel.hidden = false;
  harness.setPanelHeight(2);
  panel.scrollHeight = 40;
  controller.scheduleHeightMeasurement();
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).at(-1).height, 112);

  panel.scrollHeight = 64;
  harness.emitWidth(640);
  harness.emitWidth(640);
  assert.equal(harness.frames.size, 1);
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).at(-1).height, 136);
  const reportCount = contentSizes(harness.messages).length;
  harness.emitWidth(640);
  assert.equal(harness.frames.size, 0);
  assert.equal(contentSizes(harness.messages).length, reportCount);

  panel.scrollHeight = 120;
  harness.emitWidth(720);
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).at(-1).height, 164);

  harness.setPanelMaxHeight(48);
  harness.emitWidth(800);
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).at(-1).height, 116);

  harness.setPanelMaxHeight("0px");
  harness.emitWidth(820);
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).at(-1).height, 68);

  const invalidMetricsCount = contentSizes(harness.messages).length;
  harness.setPanelMaxHeight("");
  harness.emitWidth(840);
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).length, invalidMetricsCount);

  harness.setPanelMaxHeight("invalid");
  harness.emitWidth(860);
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).length, invalidMetricsCount);

  harness.setPanelMaxHeight("48px");
  harness.setPanelBorders("invalid", "2px");
  harness.emitWidth(880);
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).length, invalidMetricsCount);

  harness.setPanelBorders("2px", "invalid");
  harness.emitWidth(900);
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).length, invalidMetricsCount);

  harness.setPanelBorders("2px", "2px");
  panel.scrollHeight = Number.NaN;
  harness.emitWidth(920);
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).length, invalidMetricsCount);

  panel.scrollHeight = 40;
  harness.emitWidth(940);
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).at(-1).height, 112);

  panel.hidden = true;
  controller.scheduleHeightMeasurement();
  harness.flushFrame();
  assert.equal(contentSizes(harness.messages).at(-1).height, 68);

  const beforeZeroFill = contentSizes(harness.messages).length;
  controller.updateHeightPolicy({
    mode: "fillsAvailableScrollViewport",
    minimumVisibleRows: 0
  });
  assert.equal(harness.observers.size, 0);
  assert.equal(harness.frames.size, 0);
  panel.hidden = false;
  panel.scrollHeight = 120;
  controller.scheduleHeightMeasurement();
  assert.equal(harness.frames.size, 0);
  assert.equal(contentSizes(harness.messages).length, beforeZeroFill);
  controller.destroy();
});

test("teardown cancels pending measurement and disconnects the observer", () => {
  const harness = makeHeightController();
  const { controller } = harness;
  controller.updateHeightPolicy({ mode: "contentSized", minimumVisibleRows: 3, maximumVisibleRows: 10 });
  assert.equal(harness.frames.size, 1);
  assert.equal(harness.observers.size, 1);
  controller.destroy();
  assert.equal(harness.frames.size, 0);
  assert.equal(harness.observers.size, 0);
  assert.equal(contentSizes(harness.messages).length, 0);
});

test("the generated bundle carries the height transport and measurement policy", async () => {
  const source = await readFile(new URL("../codemirror.js", import.meta.url), "utf8");
  const bundle = await readFile(
    new URL("../../Sources/CodeMirror/web.bundle/codemirror.bundle.js", import.meta.url),
    "utf8"
  );
  assert.match(source, /setHeightPolicy/);
  assert.match(source, /ResizeObserver/);
  assert.match(source, /contentSize/);
  assert.match(bundle, /setHeightPolicy/);
  assert.match(bundle, /contentSize/);
});
