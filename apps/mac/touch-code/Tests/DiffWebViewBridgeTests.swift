import Foundation
import Testing

@testable import touch_code

@MainActor
struct DiffWebViewBridgeTests {

  // MARK: - Outbound

  @Test
  func encodeRenderRoundTripsDocumentFiles() throws {
    let doc = DiffDocument(
      files: [
        DiffFile(oldPath: "a.swift", newPath: "a.swift", oldContents: "old", newContents: "new")
      ],
      title: "doc-1"
    )
    let json = try DiffWebViewBridge.encodeRender(doc, configuration: .init())
    let decoded = try anyJSON(from: json)
    #expect(decoded["protocolVersion"] as? Int == 1)
    #expect(decoded["type"] as? String == "renderDocument")
    let payload = try #require(decoded["payload"] as? [String: Any])
    let document = try #require(payload["document"] as? [String: Any])
    #expect(document["identifier"] as? String == "doc-1")
    let files = try #require(document["files"] as? [[String: Any]])
    #expect(files.count == 1)
    #expect(files[0]["oldContents"] as? String == "old")
    #expect(files[0]["newContents"] as? String == "new")
  }

  @Test
  func encodeSetOptionsCarriesAllDefaults() throws {
    let json = try DiffWebViewBridge.encodeSetOptions(.init())
    let decoded = try anyJSON(from: json)
    #expect(decoded["type"] as? String == "updateConfiguration")
    let payload = try #require(decoded["payload"] as? [String: Any])
    #expect(payload["diffStyle"] as? String == "unified")
    #expect(payload["diffIndicators"] as? String == "bars")
    #expect(payload["showsLineNumbers"] as? Bool == true)
    #expect(payload["showsChangeBackgrounds"] as? Bool == true)
    #expect(payload["wrapsLines"] as? Bool == false)
    #expect(payload["showsFileHeaders"] as? Bool == true)
    #expect(payload["inlineChangeStyle"] as? String == "wordAlt")
    #expect(payload["allowsSelection"] as? Bool == true)
  }

  // MARK: - Inbound

  @Test
  func decodeReadyEventMapsToDidFinishInitialLoad() throws {
    let json = #"{"protocolVersion":1,"id":"evt-1","type":"ready","payload":{"rendererVersion":"0.1.0"}}"#
    let event = try DiffWebViewBridge.decodeEvent(json)
    #expect(event == .didFinishInitialLoad)
  }

  @Test
  func decodeRenderStateChangedRenderedReportsFileCount() throws {
    let json = #"""
    {"protocolVersion":1,"id":"evt-2","type":"renderStateChanged","payload":{"state":"rendered","documentIdentifier":"d","summary":{"fileCount":3}}}
    """#
    let event = try DiffWebViewBridge.decodeEvent(json)
    #expect(event == .didRender(fileCount: 3))
  }

  @Test
  func decodeLineActivatedReportsLineNumber() throws {
    let json = #"""
    {"protocolVersion":1,"id":"evt-3","type":"lineActivated","payload":{"fileIndex":0,"oldPath":"a.swift","newPath":"a.swift","side":"new","number":42,"kind":"addition"}}
    """#
    let event = try DiffWebViewBridge.decodeEvent(json)
    #expect(event == .didClickLine(fileIndex: 0, lineNumber: 42))
  }

  @Test
  func decodeSelectionChangedWithRangeReportsSelection() throws {
    let json = #"""
    {"protocolVersion":1,"id":"evt-4","type":"selectionChanged","payload":{"selection":{"fileIndex":2,"start":{"side":"new","number":10},"end":{"side":"new","number":15}}}}
    """#
    let event = try DiffWebViewBridge.decodeEvent(json)
    #expect(
      event == .didChangeSelection(
        SelectionRange(fileIndex: 2, start: 10, end: 15, side: .additions)))
  }

  @Test
  func decodeSelectionChangedWithNullClearsSelection() throws {
    let json = #"""
    {"protocolVersion":1,"id":"evt-5","type":"selectionChanged","payload":{"selection":null}}
    """#
    let event = try DiffWebViewBridge.decodeEvent(json)
    #expect(event == .didChangeSelection(nil))
  }

  @Test
  func decodeWrongProtocolVersionSurfacesProtocolMismatch() throws {
    let json = #"{"protocolVersion":2,"id":"evt-6","type":"ready","payload":{}}"#
    let event = try DiffWebViewBridge.decodeEvent(json)
    if case .didFail(let code, _) = event {
      #expect(code == "protocol_mismatch")
    } else {
      Issue.record("expected .didFail(code: protocol_mismatch), got \(event)")
    }
  }

  // MARK: - Helpers

  private func anyJSON(from string: String) throws -> [String: Any] {
    let data = try #require(string.data(using: .utf8))
    let raw = try JSONSerialization.jsonObject(with: data)
    return try #require(raw as? [String: Any])
  }
}
