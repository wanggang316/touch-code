import ComposableArchitecture
import SwiftUI

/// Overlay UI for the Command Palette. Presented as a floating card
/// centered near the top of the window, over whatever the
/// `NavigationSplitView` is currently showing. Dismissal is driven by
/// the parent reducer's `@Presents` pattern — activating a row or
/// pressing Escape sends a state-clear back up so the `if let` wrapper
/// removes this view from the tree.
struct CommandPaletteView: View {
  @Bindable var store: StoreOf<CommandPaletteFeature>
  /// Sent by the parent when Esc / scrim / activation requests dismiss.
  /// We don't carry a `.dismissed` reducer action here because dismissal
  /// is just "parent nil-out the @Presents slot" — the feature itself
  /// has no teardown work to do.
  let onDismiss: () -> Void

  @FocusState private var queryFocused: Bool

  var body: some View {
    ZStack {
      Color.black.opacity(0.08)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }

      VStack(spacing: 0) {
        queryField
        Divider()
        resultList
      }
      .frame(maxWidth: 560)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
      .shadow(radius: 20, y: 8)
      .padding(.top, 80)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .onAppear { queryFocused = true }
  }

  private var queryField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(
        "Quick action…",
        text: $store.query.sending(\.queryChanged)
      )
      .textFieldStyle(.plain)
      .font(.system(size: 15))
      .focused($queryFocused)
      .onKeyPress(.escape) { onDismiss(); return .handled }
      .onKeyPress(.upArrow) {
        store.send(.selectionMoved(.up))
        return .handled
      }
      .onKeyPress(.downArrow) {
        store.send(.selectionMoved(.down))
        return .handled
      }
      .onSubmit { store.send(.selectionCommitted) }
    }
    .padding(.horizontal, 14)
    .frame(height: 48)
  }

  @ViewBuilder
  private var resultList: some View {
    if store.filtered.isEmpty {
      Text(store.query.isEmpty ? "No commands available." : "No matching commands.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(24)
        .frame(maxWidth: .infinity)
    } else {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(store.filtered) { item in
            row(item, selected: item.id == store.selectionID)
              .contentShape(Rectangle())
              .onTapGesture { store.send(.rowTapped(item.id)) }
          }
        }
      }
      .frame(maxHeight: 360)
    }
  }

  private func row(_ item: CommandPaletteItem, selected: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: item.icon)
        .frame(width: 20)
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).font(.system(size: 13))
        if let subtitle = item.subtitle {
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if let shortcut = item.shortcut {
        Text(shortcut.keys.joined())
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear))
    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
  }
}
