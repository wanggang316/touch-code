// TODO(C8a Phase 4c): this handler is intentionally stubbed for Phase 3 — the IPC wire
// shape (EditorDescriptorDTO, EditorOpenRequest, argv field) still reflects C8 and needs
// a full rewrite alongside CLI changes. Phase 4c replaces this file top-to-bottom.

import ComposableArchitecture
import Foundation
import TouchCodeCore
import TouchCodeIPC

/// Placeholder server-side handler for the `editor.*` IPC surface. Every entry throws
/// `EditorIPCError.spawnFailed` (wire-level "temporary failure") until Phase 4c lands —
/// the Phase 3 commit only has to compile. Router-shape signatures match the existing
/// `MethodRouter` adapter so the IPC stack keeps wiring through to these stubs.
@MainActor
final class EditorHandlers {
  private let editor: EditorClient
  private let hierarchy: HierarchyClient

  init(editor: EditorClient, hierarchy: HierarchyClient) {
    self.editor = editor
    self.hierarchy = hierarchy
  }

  func describe() async -> EditorDescribeResponse {
    // Stub: returns an empty descriptor list. Phase 4c rewrites the DTO shape + wires
    // `editor.describe()` through.
    EditorDescribeResponse(descriptors: [])
  }

  func open(_ request: EditorOpenRequest) async throws -> EditorOpenResponse {
    _ = request
    throw EditorIPCError.spawnFailed
  }

  func setDefault(_ request: EditorSetDefaultRequest) throws -> EditorSetDefaultResponse {
    _ = request
    throw EditorIPCError.spawnFailed
  }
}
