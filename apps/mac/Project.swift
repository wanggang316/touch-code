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
      buildableFolders: [
        "TouchCodeCore",
        "TouchCodeCore/GitHub",
        "TouchCodeCore/Notifications",
        "TouchCodeCore/Shortcuts",
        "TouchCodeCore/Shortcuts/ConflictDetectors",
        "TouchCodeCore/StatusBar",
      ],
      settings: .settings(
        base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated"],
        defaultSettings: .essential
      )
    ),

    // TouchCodeCore unit tests. Links TouchCodeIPC so IPC codable tests can
    // live here too (DEC-1: avoid proliferating test targets, per 0003 and
    // 0005 M1 DEC-5 — dedicated TouchCodeIPCTests not justified).
    .target(
      name: "TouchCodeCoreTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "app.touch-code.core-tests",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: [
        "TouchCodeCoreTests",
        "TouchCodeCoreTests/IPC",
        "TouchCodeCoreTests/GitHubTests",
        "TouchCodeCoreTests/Shortcuts",
      ],
      dependencies: [
        .target(name: "TouchCodeCore"),
        .target(name: "TouchCodeIPC"),
      ],
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
      buildableFolders: ["TouchCodeIPC", "TouchCodeIPC/WireTypes"],
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

    // tcKit: shared CLI library — Transport / RPCClient / Renderer /
    // ExitCode / SocketDiscovery. The tc binary is a thin wrapper;
    // parallel plans (C5 for skill command, future CLI extensions) link
    // into tcKit rather than the tc binary.
    .target(
      name: "tcKit",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.touch-code.cli-kit",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: [
        "tcKit",
        "tcKit/Transport",
        "tcKit/Render",
      ],
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

    // tcKit unit tests. Headless — uses InMemoryTransport, does not
    // reach into the touch-code app target.
    .target(
      name: "tcKitTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "app.touch-code.cli-kit-tests",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["tcKitTests"],
      dependencies: [
        .target(name: "tcKit"),
        .target(name: "TouchCodeCore"),
        .target(name: "TouchCodeIPC"),
      ],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
        ],
        defaultSettings: .essential
      )
    ),

    // tc CLI binary. Thin wrapper around tcKit — Runtime / Hooks / Git
    // are intentionally off-limits per architecture dep rules. Isolation
    // default is `nonisolated` to match the ArgumentParser command
    // conventions (commands run off the main actor).
    .target(
      name: "tc",
      destinations: .macOS,
      product: .commandLineTool,
      bundleId: "app.touch-code.cli",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["tc", "tc/Commands"],
      dependencies: [
        .target(name: "tcKit"),
        .target(name: "TouchCodeCore"),
        .target(name: "TouchCodeIPC"),
        .external(name: "ArgumentParser"),
      ],
      settings: .settings(
        base: [
          // Debug builds intentionally skip signing so contributors without
          // a Developer ID can build the CLI. Release builds sign tc with
          // the same identity as the app — the CLI ships embedded inside
          // the .app bundle (see embed-tc.sh) and a notarized app cannot
          // contain an unsigned executable.
          "CODE_SIGNING_ALLOWED[config=Debug]": "NO",
          "PRODUCT_NAME": "tc",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
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
      productName: "TouchCode",
      bundleId: "com.gumpw.touch-agent-mac",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .file(path: "Configurations/mac-Info.plist"),
      buildableFolders: [
        "touch-code/App",
        "touch-code/App/Features/Socket",
        "touch-code/App/Features/Socket/handlers",
        "touch-code/App/Features/GitHub",
        "touch-code/App/Features/GitHub/Theme",
        "touch-code/App/Features/GitHub/Views",
        "touch-code/App/Features/MasterTerminal",
        "touch-code/App/Features/MasterTerminal/Resources",
        "touch-code/Runtime",
        "touch-code/Process",
        "touch-code/Git",
        "touch-code/GitHub",
      ],
      entitlements: .file(path: "Configurations/touch-code.entitlements"),
      // git-wt submodule wiring. Pre-script fails the build cleanly when
      // the submodule is not checked out; post-script copies only the `wt`
      // file into Resources/git-wt/wt so Bundle.main.url(forResource:
      // "wt", subdirectory: "git-wt") resolves at runtime.
      scripts: [
        .pre(
          script: "\"${SRCROOT}/scripts/verify-git-wt.sh\"",
          name: "Verify git-wt",
          basedOnDependencyAnalysis: false
        ),
        .post(
          script: "\"${SRCROOT}/scripts/embed-git-wt.sh\"",
          name: "Embed git-wt",
          inputPaths: [
            "$(SRCROOT)/ThirdParty/git-wt/wt",
          ],
          outputPaths: [
            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/git-wt/wt",
          ],
          basedOnDependencyAnalysis: false
        ),
        // tc CLI embedding. Copies the tc binary built by its sibling
        // target into Resources/bin/tc so the app can ship a single
        // self-contained .app and `tc skill install` / first-launch
        // installer (c4-cli D3) have a stable inside-bundle path to
        // symlink from ~/.local/bin/tc.
        .post(
          script: "\"${SRCROOT}/scripts/embed-tc.sh\"",
          name: "Embed tc",
          inputPaths: [
            "$(CONFIGURATION_BUILD_DIR)/tc",
          ],
          outputPaths: [
            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/tc",
          ],
          basedOnDependencyAnalysis: true
        ),
      ],
      dependencies: [
        .target(name: "TouchCodeCore"),
        .target(name: "TouchCodeIPC"),
        .target(name: "tc"),
        .target(name: "tcKit"),
        .target(name: "GhosttyKit"),
        .external(name: "ComposableArchitecture"),
      ],
      settings: .settings(
        base: [
          "ENABLE_HARDENED_RUNTIME": "YES",
          "OTHER_LDFLAGS": "$(inherited) -lc++ -framework Carbon -framework Metal -framework MetalKit -framework CoreText -framework QuartzCore",
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
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
      buildableFolders: [
        "touch-code/Tests",
        "touch-code/Tests/Socket",
        "touch-code/Tests/Harness",
        "touch-code/Tests/Integration",
        "touch-code/Tests/GitHubTests",
        "touch-code/Tests/StatusBarTests",
        "touch-code/Tests/Shortcuts",
        "touch-code/Tests/MasterTerminal",
      ],
      dependencies: [
        .target(name: "touch-code"),
        .target(name: "tcKit"),
        .external(name: "SnapshotTesting"),
      ],
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
