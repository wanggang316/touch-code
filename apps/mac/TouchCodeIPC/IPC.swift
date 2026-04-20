import Foundation

/// Top-level namespace for the touch-code JSON-RPC wire protocol.
///
/// The CLI (`tc`) and the app (`touch-code`) both import `TouchCodeIPC` and
/// switch on `IPC.Method` — wire strings are defined in exactly one place.
public enum IPC {}
