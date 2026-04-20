import Foundation
import Testing
@testable import touch_code

struct EditorEnvTests {
  @Test
  func allowlistedKeysPropagate() {
    let env = EditorEnv.build(from: ["PATH": "/usr/bin", "HOME": "/Users/test"])
    #expect(env["PATH"] == "/usr/bin")
    #expect(env["HOME"] == "/Users/test")
  }

  @Test
  func forcedLCALLAlwaysPresent() {
    let env = EditorEnv.build(from: [:])
    #expect(env["LC_ALL"] == "C.UTF-8")
  }

  @Test
  func shellIsStrippedEvenWhenSetInParent() {
    let env = EditorEnv.build(from: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"])
    #expect(env["SHELL"] == nil)
  }

  @Test
  func editorAndVisualStripped() {
    let env = EditorEnv.build(from: [
      "PATH": "/usr/bin",
      "EDITOR": "/bin/vim",
      "VISUAL": "/bin/emacs",
    ])
    #expect(env["EDITOR"] == nil)
    #expect(env["VISUAL"] == nil)
  }

  @Test
  func forbiddenKeysStripped() {
    var parent: [String: String] = ["PATH": "/usr/bin"]
    for key in EditorEnv.forbidden {
      parent[key] = "leaked"
    }
    let env = EditorEnv.build(from: parent)
    for key in EditorEnv.forbidden {
      #expect(env[key] == nil, "forbidden key '\(key)' leaked into child env")
    }
  }

  @Test
  func resultContainsOnlyAllowlistAndForced() {
    let env = EditorEnv.build(from: [
      "PATH": "/usr/bin",
      "HOME": "/Users/test",
      "SHELL": "/bin/zsh",
      "EDITOR": "/bin/vim",
      "RANDOM_VAR": "something",
    ])
    #expect(Set(env.keys) == Set(["PATH", "HOME", "LC_ALL"]))
  }
}
