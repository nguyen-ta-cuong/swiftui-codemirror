import ProjectDescription

let project = Project(
  name: "CodeMirrorHostedFocusHost",
  packages: [
    .package(path: "../..")
  ],
  settings: .settings(base: [
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "SWIFT_VERSION": "6.0",
  ]),
  targets: [
    .target(
      name: "CodeMirrorHostedFocusHost",
      destinations: .macOS,
      product: .app,
      bundleId: "com.mockphine.CodeMirrorHostedFocusHost",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .dictionary([
        "CFBundleIdentifier": .string("$(PRODUCT_BUNDLE_IDENTIFIER)"),
        "CFBundleName": .string("$(PRODUCT_NAME)"),
        "CFBundlePackageType": .string("APPL"),
        "LSBackgroundOnly": .boolean(false),
        "LSUIElement": .boolean(false),
        "NSHighResolutionCapable": .boolean(true),
        "NSPrincipalClass": .string("NSApplication"),
      ]),
      sources: ["Sources/**"],
      settings: .settings(base: [
        "CODE_SIGNING_ALLOWED": "NO"
      ])
    ),
    .target(
      name: "CodeMirrorHostedFocusHostTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "com.mockphine.CodeMirrorHostedFocusHostTests",
      deploymentTargets: .macOS("14.0"),
      sources: ["Tests/**"],
      dependencies: [
        .target(name: "CodeMirrorHostedFocusHost"),
        .package(product: "CodeMirror"),
      ],
      settings: .settings(base: [
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CODE_SIGNING_ALLOWED": "NO",
        "ENABLE_TESTABILITY": "YES",
        "TEST_HOST":
          "$(BUILT_PRODUCTS_DIR)/CodeMirrorHostedFocusHost.app/Contents/MacOS/CodeMirrorHostedFocusHost",
      ])
    ),
  ]
)
