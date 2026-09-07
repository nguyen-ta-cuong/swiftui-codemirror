import commonjs from "@rollup/plugin-commonjs";
import { nodeResolve } from "@rollup/plugin-node-resolve";
import terser from "@rollup/plugin-terser";

export default {
  input: "./codemirror.js",
  output: {
    file: "../Sources/CodeMirror/web.bundle/codemirror.bundle.js",
    format: "umd",
    name: "CodeMirrorHost",
    exports: "named",
    sourcemap: false,
    plugins: [terser()]
  },
  plugins: [nodeResolve(), commonjs()]
};
