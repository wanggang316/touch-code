import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Keyboard-first navigation for the git viewer. Attached as a `ViewModifier` on the root
/// `GitViewerView`. The host view must be `.focusable(true)` — `GitViewerView` sets that.
///
/// Bindings (0005 plan §C7 §Keyboard navigation, 0005 M4a.1 review):
/// - `j` / `k` — keyboardNavigation(.down / .up)   (unmodified only)
/// - `g` / `G` — .home / .end                      (shift-only; G is shift+g)
/// - `Tab`    — paneFocusCycled                    (unmodified only)
/// - `Enter`  — openInEditorRequested              (unmodified only)
/// - `r`      — refreshRequested                   (unmodified only)
/// - `1`/`2`/`3` — scopeChanged(.working / .staged / .log)   (unmodified only)
/// - `.`      — whitespaceToggled                  (unmodified only)
/// - `/`      — filterFocusRequested                (unmodified only; pulls focus into
///                                                   FileChangeListView's filter field)
///
/// Every unmodified binding guards against `Cmd-X` / `Control-X` / `Option-X` via
/// `press.modifiers.isEmpty` so standard macOS shortcuts (Cmd-R reload, Cmd-1 tab switch,
/// Cmd-. cancel) pass through. `g` is the only exception: `Shift-G` is part of its
/// contract; other modifier combinations return `.ignored`.
struct GitViewerKeybindings: ViewModifier {
  @Bindable var store: StoreOf<GitViewerFeature>

  func body(content: Content) -> some View {
    content
      .onKeyPress(keys: ["j"]) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        store.send(.keyboardNavigation(.down))
        return .handled
      }
      .onKeyPress(keys: ["k"]) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        store.send(.keyboardNavigation(.up))
        return .handled
      }
      .onKeyPress(keys: ["g"]) { press in
        // Only shift is allowed. Cmd/Ctrl/Option-g fall through to the next handler.
        let allowed = press.modifiers.subtracting(.shift)
        guard allowed.isEmpty else { return .ignored }
        if press.modifiers.contains(.shift) {
          store.send(.keyboardNavigation(.end))
        } else {
          store.send(.keyboardNavigation(.home))
        }
        return .handled
      }
      .onKeyPress(keys: ["r"]) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        store.send(.refreshRequested)
        return .handled
      }
      .onKeyPress(keys: ["1"]) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        store.send(.scopeChanged(.working))
        return .handled
      }
      .onKeyPress(keys: ["2"]) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        store.send(.scopeChanged(.staged))
        return .handled
      }
      .onKeyPress(keys: ["3"]) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        store.send(.scopeChanged(.log))
        return .handled
      }
      .onKeyPress(keys: ["."]) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        store.send(.whitespaceToggled)
        return .handled
      }
      .onKeyPress(keys: ["/"]) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        store.send(.filterFocusRequested)
        return .handled
      }
      .onKeyPress(keys: [.tab]) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        store.send(.paneFocusCycled)
        return .handled
      }
      .onKeyPress(keys: [.return]) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        store.send(.openInEditorRequested)
        return .handled
      }
  }
}
