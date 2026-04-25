import Foundation
import Testing

@testable import TouchCodeCore

struct ProjectKindTests {
  @Test
  func projectWithGitRootIsGitRepo() {
    let project = Project(name: "p", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    #expect(project.kind == .gitRepo)
  }

  @Test
  func projectWithoutGitRootIsPlainDir() {
    let project = Project(name: "p", rootPath: "/tmp/p", gitRoot: nil)
    #expect(project.kind == .plainDir)
  }

  @Test
  func rawValuesAreSnakeCase() {
    #expect(ProjectKind.gitRepo.rawValue == "git_repo")
    #expect(ProjectKind.plainDir.rawValue == "plain_dir")
  }
}
