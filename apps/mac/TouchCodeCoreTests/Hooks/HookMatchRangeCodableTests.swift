import Foundation
import Testing

@testable import TouchCodeCore

struct HookMatchRangeCodableTests {
  @Test
  func roundTrip() throws {
    let range = HookMatchRange(start: 120, length: 22)
    let data = try JSONEncoder().encode(range)
    let decoded = try JSONDecoder().decode(HookMatchRange.self, from: data)
    #expect(decoded == range)
  }

  @Test
  func wireShapeIsStartAndLength() throws {
    let range = HookMatchRange(start: 0, length: 4)
    let data = try JSONEncoder().encode(range)
    let s = String(bytes: data, encoding: .utf8) ?? ""
    #expect(s.contains("\"start\":0"))
    #expect(s.contains("\"length\":4"))
    #expect(!s.contains("location"))
  }
}
