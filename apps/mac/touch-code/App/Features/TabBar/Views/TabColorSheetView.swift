import SwiftUI
import TouchCodeCore

/// Sheet-hosted color picker for a single tab. Horizontal row of circular
/// swatches. Commits on Done, discards on Esc / Cancel. Mirrors `TabRenameSheetView` shape.
struct TabColorSheetView: View {
  let currentColor: TabColor?
  let onCommit: (TabColor) -> Void
  let onCancel: () -> Void

  @State private var selectedColor: TabColor

  init(
    currentColor: TabColor?,
    onCommit: @escaping (TabColor) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.currentColor = currentColor
    self.onCommit = onCommit
    self.onCancel = onCancel
    _selectedColor = State(initialValue: currentColor ?? TabColor.allCases.first!)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Tab Color")
          .font(.headline)
        Text("Choose an accent color for the tab indicator.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 12) {
        ForEach(TabColor.allCases, id: \.self) { color in
          swatch(color: color, label: color.rawValue.capitalized)
        }
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Done", action: { onCommit(selectedColor) })
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 460)
  }

  private func swatch(color: TabColor, label: String) -> some View {
    let isSelected = selectedColor == color
    let fillColor: Color = color.swiftUIColor

    return Button {
      selectedColor = color
    } label: {
      ZStack {
        Circle()
          .fill(fillColor)
          .frame(width: 28, height: 28)

        if isSelected {
          Circle()
            .strokeBorder(.primary, lineWidth: 2.5)
            .frame(width: 28, height: 28)

          Image(systemName: "checkmark")
            .font(.caption.bold())
            .foregroundStyle(.white)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

#if DEBUG
  #Preview {
    TabColorSheetView(
      currentColor: .blue,
      onCommit: { _ in },
      onCancel: {}
    )
  }
#endif
