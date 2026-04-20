import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Keyboard-first navigation for the git viewer. Attached as a `ViewModifier` on the root
/// `GitViewerView`. The host view must be `.focusable(true)` — `GitViewerView` sets that.
///
/// Bindings (0005 plan §C7 §Keyboard navigation):
/// - `j` / `k` — keyboardNavigation(.down / .up)
/// - `g` / `G` — .home / .end
/// - `Tab`    — paneFocusCycled
/// - `Enter`  — commit click in log → commitSelected; file-row → openInEditorRequested
/// - `r`      — refreshRequested
/// - `1`/`2`/`3` — scopeChanged(.working / .staged / .log)
/// - `.`      — whitespaceToggled
/// - `/`      — focus filter (deferred to M4b)
///
/// SwiftUI's `Tab` key is reserved for focus traversal; users can still cycle panes via
/// `Cmd-Tab`-style shortcut in a later pass. M4a binds plain letters only.
struct GitViewerKeybindings: ViewModifier {
  @Bindable var store: StoreOf<GitViewerFeature>

  func body(content: Content) -> some View {
    content
      .onKeyPress(keys: ["j"]) { _ in
        store.send(.keyboardNavigation(.down))
        return .handled
      }
      .onKeyPress(keys: ["k"]) { _ in
        store.send(.keyboardNavigation(.up))
        return .handled
      }
      .onKeyPress(keys: ["g"]) { press in
        if press.modifiers.contains(.shift) {
          store.send(.keyboardNavigation(.end))
        } else {
          store.send(.keyboardNavigation(.home))
        }
        return .handled
      }
      .onKeyPress(keys: ["r"]) { _ in
        store.send(.refreshRequested)
        return .handled
      }
      .onKeyPress(keys: ["1"]) { _ in
        store.send(.scopeChanged(.working))
        return .handled
      }
      .onKeyPress(keys: ["2"]) { _ in
        store.send(.scopeChanged(.staged))
        return .handled
      }
      .onKeyPress(keys: ["3"]) { _ in
        store.send(.scopeChanged(.log))
        return .handled
      }
      .onKeyPress(keys: ["."]) { _ in
        store.send(.whitespaceToggled)
        return .handled
      }
      .onKeyPress(.return) {
        store.send(.openInEditorRequested)
        return .handled
      }
  }
}
