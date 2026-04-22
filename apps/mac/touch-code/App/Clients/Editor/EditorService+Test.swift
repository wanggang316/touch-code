import AppKit
import Foundation
import TouchCodeCore

/// In-memory `EditorService` for tests. Holds canned `describe()` / `resolve()` / `open()`
/// outputs and records every open call for assertion. Designed to drop into TCA `TestStore`s
/// via `$0.editorClient = .mock(TestEditorService(...))` — see `EditorClient.testValue`.
///
/// An `actor` (rather than a struct) is used for the same reason as the live service:
/// callers are free to mutate stub behaviour between invocations from any context.
final actor TestEditorService: EditorService {
  /// Descriptors returned by `describe()`. Default: an empty list (no editors installed).
  private var describeStub: [EditorDescriptor]
  /// Closure used by `resolve()`. When nil, returns `TestEditorService.defaultDescriptor`.
  private var resolveStub: (@Sendable (EditorID?) throws -> EditorDescriptor)?
  /// Closure used by `open()`. When nil, returns `TestEditorService.defaultChoice`.
  private var openStub: (@Sendable (URL, EditorID?) throws -> EditorChoice)?

  /// Every `open` invocation in call order.
  private(set) var openCalls: [OpenCall] = []

  struct OpenCall: Equatable, Sendable {
    let directory: URL
    let preferred: EditorID?
  }

  init(
    describe: [EditorDescriptor] = [],
    resolve: (@Sendable (EditorID?) throws -> EditorDescriptor)? = nil,
    open: (@Sendable (URL, EditorID?) throws -> EditorChoice)? = nil
  ) {
    self.describeStub = describe
    self.resolveStub = resolve
    self.openStub = open
  }

  // MARK: - Stub mutators

  func setDescribeStub(_ descriptors: [EditorDescriptor]) { describeStub = descriptors }
  func setResolveStub(_ stub: (@Sendable (EditorID?) throws -> EditorDescriptor)?) { resolveStub = stub }
  func setOpenStub(_ stub: (@Sendable (URL, EditorID?) throws -> EditorChoice)?) { openStub = stub }

  // MARK: - EditorService

  func describe() -> [EditorDescriptor] { describeStub }

  func resolve(preferred: EditorID?) throws -> EditorDescriptor {
    if let resolveStub { return try resolveStub(preferred) }
    if let preferred, let match = describeStub.first(where: { $0.id == preferred }) {
      return match
    }
    return describeStub.first(where: { $0.id == EditorRegistry.finderID })
      ?? Self.defaultDescriptor
  }

  @discardableResult
  func open(directory: URL, preferred: EditorID?) throws -> EditorChoice {
    openCalls.append(OpenCall(directory: directory, preferred: preferred))
    if let openStub { return try openStub(directory, preferred) }
    return Self.defaultChoice
  }

  // MARK: - Fixtures

  static let defaultDescriptor = EditorDescriptor(
    id: EditorRegistry.finderID,
    displayName: "Finder",
    bundleIdentifier: "com.apple.finder",
    launchMode: .directory,
    appURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
    alternateBundleIdentifiers: []
  )

  static let defaultChoice = EditorChoice(
    id: EditorRegistry.finderID,
    displayName: "Finder",
    binaryPath: nil
  )
}

/// Recording double for `AppLauncher`. Used by `LiveEditorService` unit tests to verify the
/// `(appURL, urls, configuration.arguments, configuration.createsNewApplicationInstance)`
/// tuple produced by each launch-mode branch without ever asking `NSWorkspace` to open
/// anything.
final class RecordingAppLauncher: AppLauncher, @unchecked Sendable {
  /// Bundle IDs that should appear installed. Map keys are bundle IDs; values are the app
  /// URLs the launcher will return from `urlForApplication(bundleIdentifier:)`.
  var installedApps: [String: URL] = [:]
  /// Recorded invocations of `open(urls:withApplicationAt:configuration:)`.
  private(set) var openCalls: [OpenCall] = []
  /// When set, the next `open` call throws this error.
  var openError: Error?

  struct OpenCall: Sendable {
    let urls: [URL]
    let appURL: URL
    let arguments: [String]
    let createsNewApplicationInstance: Bool
  }

  init(installedApps: [String: URL] = [:]) {
    self.installedApps = installedApps
  }

  func urlForApplication(bundleIdentifier: String) -> URL? {
    installedApps[bundleIdentifier]
  }

  func open(
    urls: [URL],
    withApplicationAt appURL: URL,
    configuration: NSWorkspace.OpenConfiguration
  ) async throws {
    openCalls.append(
      OpenCall(
        urls: urls,
        appURL: appURL,
        arguments: configuration.arguments,
        createsNewApplicationInstance: configuration.createsNewApplicationInstance
      )
    )
    if let openError { throw openError }
  }
}
