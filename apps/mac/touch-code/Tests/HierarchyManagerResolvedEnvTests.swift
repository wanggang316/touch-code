import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

struct HierarchyManagerResolvedEnvTests {
  @Test
  func emptyProjectEnvVarsReturnsProcessEnvUnchanged() {
    let pid = ProjectID()
    var settings = Settings.default
    settings.projects[pid] = ProjectSettings()
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: settings)
    #expect(resolved == ProcessInfo.processInfo.environment)
  }

  @Test
  func projectEnvVarsAreLayeredOnTopOfProcessEnv() {
    let pid = ProjectID()
    var settings = Settings.default
    settings.projects[pid] = ProjectSettings(envVars: ["MY_PROJECT_VAR": "hello"])
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: settings)
    #expect(resolved["MY_PROJECT_VAR"] == "hello")
    // Process env keys still present.
    #expect(resolved["PATH"] == ProcessInfo.processInfo.environment["PATH"])
  }

  @Test
  func projectEnvVarsOverrideProcessEnvOnCollision() {
    let pid = ProjectID()
    let collidingKey = ProcessInfo.processInfo.environment.keys.first ?? "HOME"
    var settings = Settings.default
    settings.projects[pid] = ProjectSettings(envVars: [collidingKey: "PROJECT_WINS"])
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: settings)
    #expect(resolved[collidingKey] == "PROJECT_WINS")
  }

  @Test
  func unknownProjectIDReturnsProcessEnvOnly() {
    let pid = ProjectID()  // not in settings.projects
    let resolved = HierarchyManager.resolvedEnv(for: pid, in: .default)
    #expect(resolved == ProcessInfo.processInfo.environment)
  }
}
