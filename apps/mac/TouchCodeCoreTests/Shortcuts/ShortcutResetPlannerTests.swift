import Foundation
import Testing

@testable import TouchCodeCore

/// Tests for the cascading-reset planner. Most scenarios use a small, hand-built schema so
/// the colliding-default scenarios are explicit and don't depend on the production registry's
/// chord choices. The system-fixed scenario uses `ShortcutSchema.app` because that schema is
/// the one carrying `.systemFixed` rows in production.
struct ShortcutResetPlannerTests {
  // MARK: - Helpers

  private static func binding(_ keyCode: UInt16, _ modifiers: ModifierMask = .command) -> ShortcutBinding {
    ShortcutBinding(keyCode: keyCode, modifiers: modifiers)
  }

  /// A miniature schema using the tab-related `CommandID` cases as stand-in commands. The
  /// defaults are deliberately picked to be non-colliding among themselves so that any
  /// collision the planner sees comes from user overrides we install in the test.
  private static func miniSchema(
    a: ShortcutBinding,
    b: ShortcutBinding,
    c: ShortcutBinding? = nil
  ) -> ShortcutSchema {
    var entries: [ShortcutSchema.Entry] = [
      .init(id: .newTab, title: "A", category: .tabs, scope: .configurable, defaultBinding: a),
      .init(id: .closeTab, title: "B", category: .tabs, scope: .configurable, defaultBinding: b),
    ]
    if let c {
      entries.append(
        .init(id: .previousTab, title: "C", category: .tabs, scope: .configurable, defaultBinding: c)
      )
    }
    return ShortcutSchema(entries: entries)
  }

  // MARK: - Tests

  @Test
  func resettingCommandWithoutOverrideIsNoOp() {
    let schema = Self.miniSchema(a: Self.binding(0x01), b: Self.binding(0x02))
    let plan = ShortcutResetPlanner.plan(
      resetting: .newTab,
      schema: schema,
      overrides: .empty
    )

    #expect(plan.target == .newTab)
    #expect(plan.cascadingResets.isEmpty)
    #expect(plan.resultingMap == ShortcutResolver.resolve(schema: schema, overrides: .empty))
  }

  @Test
  func resettingWhenDefaultDoesNotCollideHasEmptyCascade() {
    // A's default is 0x01; we override A to 0x99. B has its default 0x02.
    // Resetting A puts A back on 0x01 — no collision with B (0x02).
    let schema = Self.miniSchema(a: Self.binding(0x01), b: Self.binding(0x02))
    let overrides = ShortcutOverrideStore(overrides: [
      .newTab: Self.binding(0x99, [.command, .shift]),
    ])

    let plan = ShortcutResetPlanner.plan(
      resetting: .newTab,
      schema: schema,
      overrides: overrides
    )

    #expect(plan.target == .newTab)
    #expect(plan.cascadingResets.isEmpty)
    let aResolved = plan.resultingMap[.newTab]
    #expect(aResolved?.binding == Self.binding(0x01))
    #expect(aResolved?.source == .schemaDefault)
  }

  @Test
  func swapConflictCascadesToClearOpposingOverride() {
    // The canonical swap: A's default == B's user override, B's default == A's user override.
    // Resetting A → A reverts to A_default (== B's override) → cascade clears B → B reverts
    // to B_default. Final: A on A_default, B on B_default.
    let aDefault = Self.binding(0x10)
    let bDefault = Self.binding(0x20)
    let schema = Self.miniSchema(a: aDefault, b: bDefault)

    let overrides = ShortcutOverrideStore(overrides: [
      .newTab: bDefault, // A overridden to B's default
      .closeTab: aDefault, // B overridden to A's default
    ])

    let plan = ShortcutResetPlanner.plan(
      resetting: .newTab,
      schema: schema,
      overrides: overrides
    )

    #expect(plan.target == .newTab)
    #expect(plan.cascadingResets == [.closeTab])

    let aResolved = plan.resultingMap[.newTab]
    let bResolved = plan.resultingMap[.closeTab]
    #expect(aResolved?.binding == aDefault)
    #expect(aResolved?.source == .schemaDefault)
    #expect(bResolved?.binding == bDefault)
    #expect(bResolved?.source == .schemaDefault)
  }

  @Test
  func systemFixedCommandsNeverAppearInCascadeList() {
    // Use the production schema so we have a real `.systemFixed` row (`.openSettings` on
    // ⌘,). Bind `.commandPaletteToggle` (configurable) to the same chord as `.openSettings`.
    // Resetting any unrelated configurable target must not cascade-clear
    // `.commandPaletteToggle` because of the `.systemFixed` collision, and `.openSettings`
    // itself must never appear as a cascade victim.
    guard let openSettingsDefault = ShortcutSchema.app.entry(for: .openSettings)?.defaultBinding else {
      Issue.record("Missing schema entry for .openSettings.")
      return
    }

    // Override `.commandPaletteToggle` to the same chord as `.openSettings`'s system-fixed
    // default. Also override `.newTab` arbitrarily so we have a well-defined reset target
    // whose default does not collide with anything.
    let overrides = ShortcutOverrideStore(overrides: [
      .commandPaletteToggle: openSettingsDefault,
      .newTab: Self.binding(0xFE, [.command, .control, .option, .shift]),
    ])

    let plan = ShortcutResetPlanner.plan(
      resetting: .newTab,
      schema: .app,
      overrides: overrides
    )

    #expect(plan.target == .newTab)
    #expect(!plan.cascadingResets.contains(.openSettings))
    #expect(!plan.cascadingResets.contains(.commandPaletteToggle))

    // The intentional configurable-vs-systemFixed collision survives the reset: the user's
    // deliberate `.commandPaletteToggle` override is still in place.
    let palette = plan.resultingMap[.commandPaletteToggle]
    #expect(palette?.binding == openSettingsDefault)
    #expect(palette?.source == .userOverride)
  }

  @Test
  func threeWayCycleTerminatesAndProducesCleanState() {
    // A_default = X1, B_default = X2, C_default = X3.
    // Overrides form a rotation: A → X2, B → X3, C → X1.
    // Reset A → A reverts to X1 (== C's override) → cascade clears C → C reverts to X3
    // (== B's override) → cascade clears B → B reverts to X2. Final: every command on its
    // default, no further work to do.
    let x1 = Self.binding(0x30)
    let x2 = Self.binding(0x31)
    let x3 = Self.binding(0x32)
    let schema = Self.miniSchema(a: x1, b: x2, c: x3)

    let overrides = ShortcutOverrideStore(overrides: [
      .newTab: x2,
      .closeTab: x3,
      .previousTab: x1,
    ])

    let plan = ShortcutResetPlanner.plan(
      resetting: .newTab,
      schema: schema,
      overrides: overrides
    )

    #expect(plan.target == .newTab)
    #expect(Set(plan.cascadingResets) == Set([.closeTab, .previousTab]))

    for id in [CommandID.newTab, .closeTab, .previousTab] {
      let resolved = plan.resultingMap[id]
      #expect(resolved?.source == .schemaDefault, "\(id) should be back on its schema default.")
    }
    #expect(plan.resultingMap[.newTab]?.binding == x1)
    #expect(plan.resultingMap[.closeTab]?.binding == x2)
    #expect(plan.resultingMap[.previousTab]?.binding == x3)
  }
}
