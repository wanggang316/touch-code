import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Add Project sheet body. Pure View over `AddProjectFeature.State`; the
/// parent sidebar view scopes the store via `store.scope(state: \.addProject,
/// action: \.addProject)` and presents this in a SwiftUI `.sheet` when the
/// scoped store is non-nil.
struct AddProjectSheet: View {
  @Bindable var store: StoreOf<AddProjectFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Add Project")
        .font(.headline)

      folderRow
      if let duplicate = store.duplicate {
        duplicateBanner(duplicate: duplicate)
      }
      classificationRow
      if store.pickedPath != nil && store.duplicate == nil {
        nameRow
      }
      if let message = store.validationError {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("Cancel") { store.send(.cancelTapped) }
          .keyboardShortcut(.cancelAction)
        Button("Add") { store.send(.submitTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(!store.canSubmit)
      }
    }
    .padding(24)
    .frame(width: 440)
  }

  // MARK: - Rows

  @ViewBuilder
  private var folderRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Folder")
          .font(.subheadline.weight(.medium))
        Text(store.pickedPath ?? "No folder selected")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Button("Choose…") { store.send(.openPickerTapped) }
    }
  }

  @ViewBuilder
  private func duplicateBanner(
    duplicate: AddProjectFeature.DuplicateRegistration
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text("This folder is already registered as a Project.")
        .font(.callout)
      Spacer()
      Button("Reveal existing") { store.send(.revealExistingTapped) }
    }
    .padding(10)
    .background(Color.orange.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  @ViewBuilder
  private var classificationRow: some View {
    if let isGit = store.pickedIsGit {
      Label(
        isGit ? "Git repository" : "Folder (non-git Project)",
        systemImage: isGit ? "point.3.connected.trianglepath.dotted" : "folder"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    } else if store.pickedPath != nil && store.duplicate == nil {
      HStack(spacing: 6) {
        ProgressView()
          .scaleEffect(0.6)
        Text("Checking…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var nameRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Project name")
        .font(.subheadline.weight(.medium))
      TextField(
        "Project name",
        text: Binding(
          get: { store.nameDraft },
          set: { store.send(.nameDraftChanged($0)) }
        )
      )
      .textFieldStyle(.roundedBorder)
    }
  }
}
