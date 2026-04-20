import Foundation
import Testing

@testable import TouchCodeCore

struct EditorValidatorsTests {
  // MARK: - CommandTemplate.validate

  @Test
  func acceptsSingleDirTemplate() throws {
    let template = CommandTemplate(binary: "code", args: ["{dir}"])
    try template.validate()
  }

  @Test
  func acceptsMultiArgTemplateWithDir() throws {
    let template = CommandTemplate(binary: "open", args: ["-a", "Xcode", "{dir}"])
    try template.validate()
  }

  @Test
  func rejectsEmptyBinary() {
    let template = CommandTemplate(binary: "", args: ["{dir}"])
    #expect(throws: EditorTemplateError.emptyBinary) {
      try template.validate()
    }
  }

  @Test
  func rejectsMissingDirPlaceholder() {
    let template = CommandTemplate(binary: "code", args: ["--help"])
    #expect(throws: EditorTemplateError.missingDirPlaceholder) {
      try template.validate()
    }
  }

  @Test
  func rejectsEmptyArgs() {
    let template = CommandTemplate(binary: "code", args: [])
    #expect(throws: EditorTemplateError.missingDirPlaceholder) {
      try template.validate()
    }
  }

  @Test
  func rejectsDuplicateDirPlaceholder() {
    let template = CommandTemplate(binary: "code", args: ["{dir}", "{dir}"])
    #expect(throws: EditorTemplateError.duplicateDirPlaceholder) {
      try template.validate()
    }
  }

  // MARK: - CustomEditor.validatedID

  @Test
  func acceptsSimpleID() throws {
    let id = try CustomEditor.validatedID("vscode")
    #expect(id == "vscode")
  }

  @Test
  func acceptsHyphenatedID() throws {
    let id = try CustomEditor.validatedID("my-editor")
    #expect(id == "my-editor")
  }

  @Test
  func acceptsUnderscoredID() throws {
    let id = try CustomEditor.validatedID("a_b_c")
    #expect(id == "a_b_c")
  }

  @Test
  func acceptsDigitsAfterLeadingAlpha() throws {
    let id = try CustomEditor.validatedID("code2")
    #expect(id == "code2")
  }

  @Test
  func acceptsMaxLengthID() throws {
    let raw = "a" + String(repeating: "b", count: 31)
    let id = try CustomEditor.validatedID(raw)
    #expect(id == raw)
    #expect(id.count == 32)
  }

  @Test
  func rejectsLeadingDigit() {
    #expect(throws: EditorTemplateError.invalidID("1abc")) {
      try CustomEditor.validatedID("1abc")
    }
  }

  @Test
  func rejectsUppercase() {
    #expect(throws: EditorTemplateError.invalidID("Vscode")) {
      try CustomEditor.validatedID("Vscode")
    }
  }

  @Test
  func rejectsEmpty() {
    #expect(throws: EditorTemplateError.invalidID("")) {
      try CustomEditor.validatedID("")
    }
  }

  @Test
  func rejectsSingleChar() {
    #expect(throws: EditorTemplateError.invalidID("a")) {
      try CustomEditor.validatedID("a")
    }
  }

  @Test
  func rejectsOverMaxLength() {
    let raw = "a" + String(repeating: "a", count: 32)
    #expect(throws: EditorTemplateError.invalidID(raw)) {
      try CustomEditor.validatedID(raw)
    }
  }

  @Test
  func rejectsSpace() {
    #expect(throws: EditorTemplateError.invalidID("my editor")) {
      try CustomEditor.validatedID("my editor")
    }
  }

  @Test
  func rejectsSlash() {
    #expect(throws: EditorTemplateError.invalidID("a/b")) {
      try CustomEditor.validatedID("a/b")
    }
  }

  @Test
  func rejectsLeadingHyphen() {
    #expect(throws: EditorTemplateError.invalidID("-abc")) {
      try CustomEditor.validatedID("-abc")
    }
  }
}
