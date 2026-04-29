import SwiftUI

// MARK: - Public model

/// A document the diff renderer consumes. Contains one or more `DiffFile`s
/// to render and an optional title used by the renderer's file-header row.
public struct DiffDocument: Equatable, Sendable {
  public let files: [DiffFile]
  public let title: String?
  /// When provided, the renderer uses this unified-diff text instead of
  /// computing the diff from `oldContents` / `newContents`. Useful when
  /// authoritative `git diff` output already exists (e.g. for renames).
  public let fallbackPatch: String?

  public init(files: [DiffFile], title: String? = nil, fallbackPatch: String? = nil) {
    self.files = files
    self.title = title
    self.fallbackPatch = fallbackPatch
  }
}

/// A single file in a `DiffDocument`. `oldPath` / `newPath` are nil for
/// pure additions / deletions respectively.
public struct DiffFile: Equatable, Sendable, Identifiable {
  public var id: String { newPath ?? oldPath ?? "" }
  public let oldPath: String?
  public let newPath: String?
  public let oldContents: String
  public let newContents: String

  public init(
    oldPath: String?,
    newPath: String?,
    oldContents: String,
    newContents: String
  ) {
    self.oldPath = oldPath
    self.newPath = newPath
    self.oldContents = oldContents
    self.newContents = newContents
  }
}

// MARK: - Public configuration

/// Renderer configuration. All flags map to the underlying JS bridge's
/// `setOptions` payload — adding a new option here requires bumping the
/// bridge protocol version.
public struct DiffConfiguration: Equatable, Sendable {
  public var appearance: DiffAppearance
  public var style: DiffStyle
  public var indicators: DiffIndicators
  public var showsLineNumbers: Bool
  public var showsChangeBackgrounds: Bool
  public var wrapsLines: Bool
  public var showsFileHeaders: Bool
  public var inlineChangeStyle: InlineChangeStyle
  public var allowsSelection: Bool

  public init(
    appearance: DiffAppearance = .automatic,
    style: DiffStyle = .unified,
    indicators: DiffIndicators = .bars,
    showsLineNumbers: Bool = true,
    showsChangeBackgrounds: Bool = true,
    wrapsLines: Bool = false,
    showsFileHeaders: Bool = true,
    inlineChangeStyle: InlineChangeStyle = .wordAlt,
    allowsSelection: Bool = true
  ) {
    self.appearance = appearance
    self.style = style
    self.indicators = indicators
    self.showsLineNumbers = showsLineNumbers
    self.showsChangeBackgrounds = showsChangeBackgrounds
    self.wrapsLines = wrapsLines
    self.showsFileHeaders = showsFileHeaders
    self.inlineChangeStyle = inlineChangeStyle
    self.allowsSelection = allowsSelection
  }
}

public enum DiffAppearance: String, Equatable, Sendable, Codable {
  case automatic, light, dark
}

public enum DiffStyle: String, Equatable, Sendable, Codable {
  case unified, split
}

public enum DiffIndicators: String, Equatable, Sendable, Codable {
  case bars, classic, none
}

public enum InlineChangeStyle: String, Equatable, Sendable, Codable {
  case wordAlt, word, char, none
}

// MARK: - Public events

/// Events surfaced from the underlying WKWebView renderer back to the host.
public enum DiffEvent: Equatable, Sendable {
  case didFinishInitialLoad
  case didRender(fileCount: Int)
  case didClickLine(fileIndex: Int, lineNumber: Int)
  case didChangeSelection(SelectionRange?)
  case didFail(code: String, message: String)
}

public struct SelectionRange: Equatable, Sendable {
  public let fileIndex: Int
  public let start: Int
  public let end: Int
  public let side: SelectionSide

  public init(fileIndex: Int, start: Int, end: Int, side: SelectionSide) {
    self.fileIndex = fileIndex
    self.start = start
    self.end = end
    self.side = side
  }
}

public enum SelectionSide: String, Equatable, Sendable, Codable {
  case additions, deletions, both
}

// MARK: - Public view

/// SwiftUI entry point for rendering a `DiffDocument`. Backed by a
/// `WKWebView` running the vendored `WebAssets/renderer.js` bundle. M2
/// ships a placeholder body; M3 wires up the WebView host + bridge.
public struct DiffRendererView: View {
  public let document: DiffDocument
  public let configuration: DiffConfiguration
  public let onEvent: ((DiffEvent) -> Void)?

  public init(
    document: DiffDocument,
    configuration: DiffConfiguration = .init(),
    onEvent: ((DiffEvent) -> Void)? = nil
  ) {
    self.document = document
    self.configuration = configuration
    self.onEvent = onEvent
  }

  public var body: some View {
    DiffWebView(
      document: document,
      configuration: configuration,
      onEvent: onEvent
    )
  }
}
