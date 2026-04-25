import Foundation
import SwiftUI
import Testing

@testable import touch_code

/// `OptionalOverridePicker` is a thin wrapper over SwiftUI's `Picker`; the
/// only logic we own is the inherit-row label composition and the binding
/// pass-through. Tests exercise both directly without rendering — pure
/// helpers cover the label, and `Binding(get:set:)` round-trips cover the
/// binding contract.
struct OptionalOverridePickerTests {
  // MARK: - Inherit row label

  /// `inheritRowText` composes the "Use global default — <inherited>" string;
  /// when the inheritedLabel returns empty (no global default set), the row
  /// falls back to a bare "Use global default" rather than dangling on the
  /// em-dash.
  @Test
  func inheritRowTextOmitsEmDashWhenInheritedLabelEmpty() {
    let text = OptionalOverridePicker<String>.inheritRowText(
      inheritedLabel: { _ in "" },
      inheritedValue: nil
    )
    #expect(text == "Use global default")
  }

  @Test
  func inheritRowTextRendersResolvedInheritedValue() {
    let text = OptionalOverridePicker<String>.inheritRowText(
      inheritedLabel: { value in value ?? "Cursor" },
      inheritedValue: nil
    )
    #expect(text == "Use global default — Cursor")
  }

  @Test
  func inheritRowTextThreadsExplicitInheritedValueIntoFormatter() {
    let text = OptionalOverridePicker<String>.inheritRowText(
      inheritedLabel: { value in value ?? "fallback" },
      inheritedValue: "vscode"
    )
    #expect(text == "Use global default — vscode")
  }

  // MARK: - Binding pass-through

  /// Selecting `.tag(nil)` on the Picker is equivalent to assigning nil to
  /// the binding. The view's only contract over its binding is "writes flow
  /// through unchanged"; verify the binding round-trips both states.
  @Test
  func bindingRoundTripsNilAndExplicitValues() {
    final class Box: @unchecked Sendable {
      var stored: String? = "vscode"
    }
    let box = Box()
    let binding = Binding<String?>(
      get: { box.stored },
      set: { box.stored = $0 }
    )

    binding.wrappedValue = nil
    #expect(box.stored == nil)
    binding.wrappedValue = "cursor"
    #expect(box.stored == "cursor")
  }

  // MARK: - TriState

  @Test
  func triStateInheritLabelDescribesYesNo() {
    #expect(TriStateOverrideToggle.inheritLabel(inheritedValue: true) == "Use global default — yes")
    #expect(TriStateOverrideToggle.inheritLabel(inheritedValue: false) == "Use global default — no")
  }
}
