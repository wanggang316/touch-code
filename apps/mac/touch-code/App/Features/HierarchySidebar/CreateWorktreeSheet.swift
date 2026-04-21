import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// SwiftUI sheet for `CreateWorktreeFeature`. Minimal form: branch
/// name + live validator, base-ref dropdown, three toggles, optional
/// streaming progress log, error banner, and Cancel / Create footer.
struct CreateWorktreeSheet: View {
  @Bindable var store: StoreOf<CreateWorktreeFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Create Worktree")
        .font(.headline)

      VStack(alignment: .leading, spacing: 4) {
        Text("Branch name").font(.callout)
        TextField(
          "feature/login",
          text: Binding(
            get: { store.branchNameDraft },
            set: { store.send(.branchDraftChanged($0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .disabled(store.isSubmitting)
        if let error = store.validationError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Base ref").font(.callout)
        if store.loadingOptions {
          ProgressView()
            .controlSize(.small)
        } else {
          Picker(
            "",
            selection: Binding(
              get: { store.selectedBaseRef ?? "" },
              set: { store.send(.baseRefSelected($0.isEmpty ? nil : $0)) }
            )
          ) {
            ForEach(store.baseRefOptions, id: \.self) { ref in
              Text(ref).tag(ref)
            }
          }
          .labelsHidden()
          .disabled(store.isSubmitting)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Toggle(
          "Fetch origin before creating",
          isOn: Binding(
            get: { store.fetchOrigin },
            set: { store.send(.fetchOriginToggled($0)) }
          )
        )
        Toggle(
          "Copy ignored files",
          isOn: Binding(
            get: { store.copyIgnored },
            set: { store.send(.copyIgnoredToggled($0)) }
          )
        )
        Toggle(
          "Copy untracked files",
          isOn: Binding(
            get: { store.copyUntracked },
            set: { store.send(.copyUntrackedToggled($0)) }
          )
        )
      }
      .disabled(store.isSubmitting)

      if store.isSubmitting && !store.progressLines.isEmpty {
        ScrollView {
          Text(store.progressLines.joined(separator: "\n"))
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(height: 120)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .stroke(.secondary.opacity(0.3))
        )
      }

      if let error = store.submitError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSubmitting)

        Button("Create") {
          store.send(.createButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          store.isSubmitting
            || store.validationError != nil
            || store.branchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || store.selectedBaseRef == nil
        )
      }
    }
    .padding(20)
    .frame(width: 420)
    .onAppear { store.send(.onAppear) }
  }
}
