import Foundation
import Testing
@testable import touch_code
import TouchCodeCore

@MainActor
struct PendingOutputBufferTests {
  @Test
  func coalescesSuccessiveAppendsIntoOneEmission() async throws {
    var emissions: [(PanelID, Data)] = []
    let panelID = PanelID()
    let buffer = PendingOutputBuffer(
      panelID: panelID,
      flushInterval: .milliseconds(30),
      maxBufferSize: 1024
    ) { id, data in
      emissions.append((id, data))
    }

    buffer.append(Data([0x41, 0x42, 0x43]))
    buffer.append(Data([0x44, 0x45]))

    #expect(emissions.isEmpty)

    try await Task.sleep(for: .milliseconds(80))

    #expect(emissions.count == 1)
    #expect(emissions[0].0 == panelID)
    #expect(emissions[0].1 == Data([0x41, 0x42, 0x43, 0x44, 0x45]))
  }

  @Test
  func immediateFlushWhenBufferExceedsMax() {
    var emissions: [(PanelID, Data)] = []
    let panelID = PanelID()
    let buffer = PendingOutputBuffer(
      panelID: panelID,
      flushInterval: .seconds(10),
      maxBufferSize: 4
    ) { id, data in
      emissions.append((id, data))
    }

    buffer.append(Data([1, 2, 3, 4, 5]))

    #expect(emissions.count == 1)
    #expect(emissions[0].1.count == 5)
  }

  @Test
  func flushNowDrainsSynchronously() {
    var emissions: [(PanelID, Data)] = []
    let panelID = PanelID()
    let buffer = PendingOutputBuffer(
      panelID: panelID,
      flushInterval: .seconds(10)
    ) { id, data in
      emissions.append((id, data))
    }

    buffer.append(Data([0xFF]))
    buffer.flushNow()

    #expect(emissions.count == 1)
    #expect(emissions[0].1 == Data([0xFF]))
  }

  @Test
  func flushNowOnEmptyBufferEmitsNothing() {
    var emissions: [(PanelID, Data)] = []
    let buffer = PendingOutputBuffer(panelID: PanelID()) { id, data in
      emissions.append((id, data))
    }

    buffer.flushNow()
    #expect(emissions.isEmpty)
  }
}
