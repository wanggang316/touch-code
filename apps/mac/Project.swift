import ProjectDescription

let ghosttyXCFrameworkPath: Path = ".build/ghostty/GhosttyKit.xcframework"
let ghosttyBuildScriptPath: Path = "scripts/build-ghostty.sh"

let ghosttyFingerprintInputScript = """
"${SRCROOT}/\(ghosttyBuildScriptPath.pathString)" --print-fingerprint
"""

let project = Project(
  name: "touch-code",
  settings: .settings(
    base: [
      "CODE_SIGN_STYLE": "Automatic",
      "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
      "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
      "SWIFT_VERSION": "6.0",
    ],
    configurations: [
      .debug(name: .debug, xcconfig: "Configurations/Project.xcconfig"),
      .release(name: .release, xcconfig: "Configurations/Project.xcconfig"),
    ],
    defaultSettings: .essential
  ),
  targets: [
    // Shared domain types. Zero internal deps. Consumed by app + CLI.
    .target(
      name: "TouchCodeCore",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.touch-code.core",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["TouchCodeCore"],
      settings: .settings(
        base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated"],
        defaultSettings: .essential
      )
    ),

    // TouchCodeCore unit tests.
    .target(
      name: "TouchCodeCoreTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "app.touch-code.core-tests",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["TouchCodeCoreTests"],
      dependencies: [.target(name: "TouchCodeCore")],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        ],
        defaultSettings: .essential
      )
    ),

    // JSON-RPC wire protocol. Consumed by app + CLI.
    .target(
      name: "TouchCodeIPC",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.touch-code.ipc",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["TouchCodeIPC"],
      dependencies: [.target(name: "TouchCodeCore")],
      settings: .settings(
        base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated"],
        defaultSettings: .essential
      )
    ),

    // Ghostty foreign build. Produces GhosttyKit.xcframework from ThirdParty/ghostty.
    .foreignBuild(
      name: "GhosttyKit",
      destinations: .macOS,
      script: """
        "${SRCROOT}/\(ghosttyBuildScriptPath.pathString)"
        """,
      inputs: [
        .file("../../mise.toml"),
        .file(ghosttyBuildScriptPath),
        .script(ghosttyFingerprintInputScript),
      ],
      output: .xcframework(path: ghosttyXCFrameworkPath, linking: .static)
    ),

    // tc CLI. Thin RPC client; Runtime / Hooks / Git are intentionally off-limits.
    .target(
      name: "tc",
      destinations: .macOS,
      product: .commandLineTool,
      bundleId: "app.touch-code.cli",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["tc"],
      dependencies: [
        .target(name: "TouchCodeCore"),
        .target(name: "TouchCodeIPC"),
        .external(name: "ArgumentParser"),
      ],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "PRODUCT_NAME": "tc",
        ],
        defaultSettings: .essential
      )
    ),

    // Mac app. Runtime / Hooks / Git are in-app modules (subfolders, not separate targets).
    // tc is a dependency so app builds produce the CLI binary alongside the .app bundle.
    .target(
      name: "touch-code",
      destinations: .macOS,
      product: .app,
      bundleId: "app.touch-code.mac",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .file(path: "Configurations/mac-Info.plist"),
      buildableFolders: [
        "touch-code/App",
        "touch-code/Runtime",
        "touch-code/Runtime/Ghostty",
        "touch-code/Hooks",
        "touch-code/Git",
      ],
      dependencies: [
        .target(name: "TouchCodeCore"),
        .target(name: "TouchCodeIPC"),
        .target(name: "tc"),
        .target(name: "GhosttyKit"),
      ],
      settings: .settings(
        base: [
          "ENABLE_HARDENED_RUNTIME": "YES",
          "OTHER_LDFLAGS": "$(inherited) -lc++ -framework Carbon -framework Metal -framework MetalKit -framework CoreText -framework QuartzCore",
        ],
        defaultSettings: .essential
      )
    ),

    // touch-code unit tests (Runtime + App integration tests).
    .target(
      name: "touch-codeTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "app.touch-code.mac-tests",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["touch-code/Tests"],
      dependencies: [.target(name: "touch-code")],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        ],
        defaultSettings: .essential
      )
    ),
  ],
  additionalFiles: [
    "Configurations/**",
  ],
  resourceSynthesizers: []
)
