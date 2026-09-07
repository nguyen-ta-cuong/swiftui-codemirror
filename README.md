# CodeMirror

SwiftUI CodeMirror 6 transport for native macOS and iOS editors. The package owns the bundled WebKit page and JavaScript bridge while the host owns the authoritative text, document undo, validation, and session lifetime.

## Swift package

Add the package as a local or remote Swift package and import `CodeMirror`.

```swift
let session = CodeMirrorSession(
    initialText: "{\"enabled\":true}",
    configuration: CodeMirrorConfiguration(
        language: .json,
        editorName: "Response body"
    )
) { event in
    switch event {
    case .transaction(_, let snapshot):
        return .accept
    default:
        return .accept
    }
}

CodeMirrorEditor(session: session)
```

`CodeMirrorSession` is main-actor owned. Its event callback is synchronous so a host reducer can accept a transaction, replace it with authoritative text, or invalidate the session before the WebKit replica receives an acknowledgement. `CodeMirrorChange` ranges and selections use UTF-16 offsets; inbound changes must carry the source preimage, which the session validates and normalizes before acceptance.

Use `flush()` before saving, exporting, running, navigating, or tearing down an editor. Use `replace` for host-owned undo and redo; those replacements update replicas without generating editor events or WebKit history entries. When a reducer must apply an undo or redo replacement synchronously, `replaceImmediately(expectedRevision:changes:selection:in:)` performs the same atomic validation and replica update without an async suspension. `focusedReplicaID()` checks the current native key-window responder synchronously and returns no replica for an unmounted, hidden, inactive, invalidated, or native-form-focused view.

The supported language values are `.text`, `.json`, `.xml`, and `.graphql`. JSON formatting is lexical: it preserves number lexemes, key order, duplicate keys, and string escapes. Documents larger than 1 MiB remain editable in plain mode while syntax analysis and formatting report unavailable.

## Native editing commands

`focusedReplicaID()` reports the native key-window owner, while `focusedCommandContext()` reports trusted content or exact Find focus and Find Undo/Redo availability. A native-focused replica without a current trusted report is `.unavailable`; native fields and unrelated responders remain outside the CodeMirror command context.

For nil-target Undo/Redo, the host uses a weak per-window registration and immutable content or Find targets. Content targets route with `.contentOrCurrentFind`; a retained Find target carries its opaque `CodeMirrorFindCommandContextID` and routes with `.find(...)`, so it cannot become document Undo after focus moves. Hosts must validate the current key window, replica, context identity, and availability before dispatching `routeCommand(_:in:expecting:)`; native fields use normal responder-chain fallthrough.

`forwardedToHost` emits exactly one existing `CodeMirrorEvent.command`. The host sends that event through flush-before-Undo preparation and the shared document `UndoManager`; it must not perform a second Undo/Redo from the result. `handledByEmbeddedControl` performs only local Find history and emits no document command; `unavailable` emits none.

Inline and detached editors share their owning document session and `UndoManager`; another document owns a separate manager. Use `replaceImmediately` inside synchronous Undo callbacks and register inverses before the callback returns.

## Local bundle development

The JavaScript source and lockfile live in `codemirrorjs`.

```sh
cd codemirrorjs
npm ci
npm test
npm run build
```

The build writes the reproducible bundle to `Sources/CodeMirror/web.bundle/codemirror.bundle.js`. Run `npm run generate-notices` after dependency changes; it deterministically walks the entry-point imports, verifies each bundled runtime package against the committed lockfile, and copies its installed license/notice text into `Sources/CodeMirror/web.bundle/THIRD-PARTY-NOTICES.md`. The notice inventory also lists locked build-only and optional packages separately, without treating their metadata as runtime notices. The HTML page uses a non-networking local-only CSP and the native wrapper uses a nonpersistent WebKit data store. No application source or body text is interpolated into JavaScript source.

## Provenance

This fork is based on `jaywcjlove/swiftui-codemirror` v2.8.3 and retains the upstream acknowledgments and MIT license. CodeMirror 6 language support is provided by the CodeMirror project, `cm6-graphql` from GraphiQL, and the packages recorded in `codemirrorjs/package-lock.json`. The generated notice file is the committed provenance record for bundled runtime dependencies and the complete locked-package inventory; its header records the lockfile hash used to produce it.

## Acknowledgments

- https://codemirror.net
- https://github.com/khoi/codemirror-swift
- https://github.com/ProxymanApp/CodeMirror-Swift
- https://github.com/graphql/graphiql/tree/main/packages/cm6-graphql

## License

Licensed under the MIT License. See [LICENSE](LICENSE).
