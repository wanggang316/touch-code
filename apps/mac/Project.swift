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

    // tc CLI library. Pure-ish Swift: AgentsConfig, SkillBundleLocator, SkillInstaller,
    // SkillCommand runners — everything the tc binary needs that benefits from unit testing.
    // Separated from the commandLineTool target so test code can link against these symbols
    // (Swift test targets cannot link against a commandLineTool product). Depends only on
    // TouchCodeCore / TouchCodeIPC / ArgumentParser — never on TouchCodeCore-internals
    // patterns the app uses. `tc skill install` bypasses IPC because it operates on user
    // files rather than live app state.
    .target(
      name: "tcKit",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.touch-code.cli-kit",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["tcKit"],
      dependencies: [
        .target(name: "TouchCodeCore"),
        .target(name: "TouchCodeIPC"),
        .external(name: "ArgumentParser"),
      ],
      settings: .settings(
        base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated"],
        defaultSettings: .essential
      )
    ),

    // tc CLI. Thin wrapper over tcKit: parse argv, dispatch, print. No business logic here.
    .target(
      name: "tc",
      destinations: .macOS,
      product: .commandLineTool,
      bundleId: "app.touch-code.cli",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["tc"],
      dependencies: [
        .target(name: "tcKit"),
        .external(name: "ArgumentParser"),
      ],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "PRODUCT_NAME": "tc",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        ],
        defaultSettings: .essential
      )
    ),

    // tcKit unit tests. Links to the tcKit static framework so tests can reach every
    // non-public symbol via `@testable import tcKit`.
    .target(
      name: "tcTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "app.touch-code.cli-tests",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["tcTests"],
      dependencies: [.target(name: "tcKit")],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        ],
        defaultSettings: .essential
      )
    ),

    // Mac app. Runtime / Hooks / Git are in-app modules (subfolders, not separate targets).
    // tc is a dependency so app builds produce the CLI binary alongside the .app bundle.
    // Resources/ ships agents.json and (later milestones) the touch-code-skill bundle.
    .target(
      name: "touch-code",
      destinations: .macOS,
      product: .app,
      bundleId: "app.touch-code.mac",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .file(path: "Configurations/mac-Info.plist"),
      resources: [
        "Resources/**",
      ],
      buildableFolders: [
        "touch-code/App",
        "touch-code/Runtime",
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
