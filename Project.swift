import ProjectDescription

let ghosttyXCFrameworkPath: Path = ".build/ghostty/GhosttyKit.xcframework"
let ghosttyBuildScriptPath: Path = "scripts/build-ghostty.sh"

func shellScript(_ path: Path) -> String {
  "\"${SRCROOT}/\(path.pathString)\""
}

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
    // Packages
    .target(
      name: "Core",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.touch-code.core",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["packages/Core"]
    ),
    .target(
      name: "IPC",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.touch-code.ipc",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["packages/IPC"],
      dependencies: [.target(name: "Core")]
    ),
    .target(
      name: "Hooks",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.touch-code.hooks",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["packages/Hooks"],
      dependencies: [.target(name: "Core")]
    ),
    .target(
      name: "Runtime",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.touch-code.runtime",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["packages/Runtime"],
      // GhosttyKit dependency deferred: see DEC-8 in exec-plan/0001 (ghostty Zig
      // deps CDN returns 400 to Zig's HTTP client; curl works fine). Re-add
      // `.target(name: "GhosttyKit")` once upstream resolves.
      dependencies: [.target(name: "Core")]
    ),
    .target(
      name: "Git",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.touch-code.git",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["packages/Git"],
      dependencies: [.target(name: "Core")]
    ),

    // Ghostty foreign build — deferred (see DEC-8 in exec-plan/0001)
    // .foreignBuild(
    //   name: "GhosttyKit",
    //   destinations: .macOS,
    //   script: """
    //     "${SRCROOT}/\(ghosttyBuildScriptPath.pathString)"
    //     """,
    //   inputs: [
    //     .file("mise.toml"),
    //     .file(ghosttyBuildScriptPath),
    //     .script(ghosttyFingerprintInputScript),
    //   ],
    //   output: .xcframework(path: ghosttyXCFrameworkPath, linking: .static)
    // ),

    // CLI
    .target(
      name: "tc",
      destinations: .macOS,
      product: .commandLineTool,
      bundleId: "app.touch-code.cli",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .default,
      buildableFolders: ["apps/cli"],
      dependencies: [
        .target(name: "Core"),
        .target(name: "IPC"),
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

    // macOS App
    .target(
      name: "touch-code",
      destinations: .macOS,
      product: .app,
      bundleId: "app.touch-code.mac",
      deploymentTargets: .macOS("14.0"),
      infoPlist: .file(path: "Configurations/mac-Info.plist"),
      buildableFolders: ["apps/mac"],
      dependencies: [
        .target(name: "Core"),
        .target(name: "IPC"),
        .target(name: "Runtime"),
        .target(name: "Hooks"),
        .target(name: "Git"),
        // .target(name: "GhosttyKit"),  // Deferred: see DEC-8 in exec-plan/0001
      ],
      settings: .settings(
        base: [
          "ENABLE_HARDENED_RUNTIME": "YES",
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
