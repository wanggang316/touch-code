import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project Hooks pane (M6). Editable list of `HookSubscription` rows
/// merged from Global + Project sources, with inline `HookEditorRow`
/// editors. The header carries a `+ Add Hook` button (seeds a draft
/// already expanded with `scope = .projectID(currentProjectID)`) and
/// the existing "Reveal hooks.json in Finder" utility.
///
/// Save / Delete route through `ProjectSettingsFeature.upsertHook` /
/// `.deleteHook` on the reducer; both re-trigger `.onHooksAppear` so
/// the merged list refreshes after each write. Drafts live in view
/// state and disappear on Cancel without touching disk.
struct ProjectHooksSettingsView: View {
  let projectID: ProjectID
  let store: StoreOf<ProjectSettingsFeature>

  @Environment(HierarchyManager.self) private var hierarchyManager

  /// In-flight, not-yet-persisted draft seeded by `+ Add Hook`. Held in
  /// view state so cancelling discards without ever calling upsert.
  @State private var draftHook: HookSubscription?

  /// Unsaved subscriptions are keyed off this in-memory list so the row
  /// shows a stable id; the catalog projection is recomputed lazily.
  private var catalog: ScopePickerCatalog {
    ScopePickerCatalog.from(
      catalog: hierarchyManager.catalog,
      currentProjectID: projectID
    )
  }

  /// Look up the persisted `HookSubscription` keyed by the row's id.
  /// `HookRow` is a display-only projection; the editor needs the full
  /// model. The reducer parks the underlying subscriptions on
  /// `state.hookSubscriptions` after every `.onHooksAppear` succeeds.
  private func subscription(for rowID: UUID) -> HookSubscription? {
    store.state.hookSubscriptions.first(where: { $0.id == rowID })
  }

  var body: some View {
    Form {
      headerSection

      Section {
        switch store.state.hooksLoad {
        case .idle:
          Color.clear
            .frame(height: 1)
            .onAppear { store.send(.onHooksAppear) }

        case .loading:
          ProgressView()
            .frame(maxWidth: .infinity)

        case .loaded(let rows):
          if let draft = draftHook {
            HookEditorRow(
              subscription: draft,
              catalog: catalog,
              currentProjectID: projectID,
              onSave: { updated in
                draftHook = nil
                store.send(.upsertHook(updated))
              },
              onDelete: {
                draftHook = nil
              },
              startExpanded: true
            )
          }

          if rows.isEmpty && draftHook == nil {
            Text("No hooks configured for this project.")
              .font(.callout)
              .foregroundStyle(.secondary)
          } else {
            ForEach(rows) { row in
              if let sub = subscription(for: row.id) {
                HookEditorRow(
                  subscription: sub,
                  catalog: catalog,
                  currentProjectID: projectID,
                  onSave: { updated in
                    store.send(.upsertHook(updated))
                  },
                  onDelete: {
                    store.send(.deleteHook(row.id))
                  }
                )
              }
            }
          }

        case .failed(let error):
          VStack(alignment: .leading, spacing: 8) {
            Label("Failed to load hooks", systemImage: "exclamationmark.circle.fill")
              .foregroundColor(.red)
            Text(error)
              .font(.caption)
              .foregroundColor(.secondary)
            Button("Retry") { store.send(.onHooksAppear) }
              .buttonStyle(.bordered)
          }
        }
      }

      if let error = store.state.lastWriteFailure, !error.isEmpty {
        Section {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .foregroundColor(.red)
        }
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Header

  @ViewBuilder
  private var headerSection: some View {
    Section {
      HStack {
        Button {
          addDraftHook()
        } label: {
          Label("Add Hook", systemImage: "plus")
        }
        .disabled(draftHook != nil)

        Spacer()

        Button {
          store.send(.revealHooksJSONRequested)
        } label: {
          Label("Reveal hooks.json in Finder", systemImage: "folder")
        }
        .buttonStyle(.borderless)
      }
    }
  }

  // MARK: - Mutations

  private func addDraftHook() {
    let draft = HookSubscription(
      event: .paneReady,
      command: "",
      scope: .projectID(projectID)
    )
    draftHook = draft
  }
}

// MARK: - Pure helpers (testable without SwiftUI)

/// Pure constructor for the `+ Add Hook` draft. Mirrored as a static
/// helper so the unit test can build the same draft and assert its
/// scope without instantiating the SwiftUI view.
extension ProjectHooksSettingsView {
  nonisolated static func makeDraftHook(currentProjectID: ProjectID) -> HookSubscription {
    HookSubscription(
      event: .paneReady,
      command: "",
      scope: .projectID(currentProjectID)
    )
  }
}
