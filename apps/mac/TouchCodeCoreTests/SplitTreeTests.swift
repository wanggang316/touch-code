import Foundation
import Testing

@testable import TouchCodeCore

struct SplitTreeTests {
  @Test
  func emptyTreeHasNoLeaves() {
    let tree = SplitTree<PanelID>()
    #expect(tree.isEmpty)
    #expect(!tree.isSplit)
    #expect(tree.leaves().isEmpty)
  }

  @Test
  func singleLeafTree() {
    let a = PanelID()
    let tree = SplitTree(leaf: a)
    #expect(!tree.isEmpty)
    #expect(!tree.isSplit)
    #expect(tree.leaves() == [a])
    #expect(tree.contains(a))
  }

  @Test
  func insertingGrowsTree() throws {
    let a = PanelID(), b = PanelID(), c = PanelID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .inserting(c, at: b, direction: .down)

    #expect(tree.isSplit)
    #expect(tree.leaves() == [a, b, c])
  }

  @Test
  func insertingAtUnknownAnchorThrows() {
    let a = PanelID(), ghost = PanelID(), b = PanelID()
    let tree = SplitTree(leaf: a)
    #expect(throws: SplitTree<PanelID>.SplitError.leafNotFound) {
      _ = try tree.inserting(b, at: ghost, direction: .right)
    }
  }

  @Test
  func removingCollapsesSingletonSplit() throws {
    let a = PanelID(), b = PanelID()
    let tree = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)
    let afterRemoveB = tree.removing(b)
    #expect(afterRemoveB.leaves() == [a])
    #expect(!afterRemoveB.isSplit)
  }

  @Test
  func removingNonExistentLeafIsNoop() {
    let a = PanelID(), ghost = PanelID()
    let tree = SplitTree(leaf: a)
    #expect(tree.removing(ghost) == tree)
  }

  @Test
  func removingOnlyLeafYieldsEmptyTree() {
    let a = PanelID()
    let tree = SplitTree(leaf: a).removing(a)
    #expect(tree.isEmpty)
  }

  @Test
  func replacingSwapsLeafAndPreservesShape() throws {
    let a = PanelID(), b = PanelID(), c = PanelID()
    let original = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)
    let replaced = try original.replacing(b, with: c)
    #expect(replaced.leaves() == [a, c])
    #expect(replaced.isSplit)
  }

  @Test
  func pathToLeafNavigatesLeftFirst() throws {
    let a = PanelID(), b = PanelID()
    let tree = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)
    // `inserting(..., at: a, direction: .right)` places the new leaf to the right, so `a` is on left.
    let pathA = try #require(tree.path(to: a))
    let pathB = try #require(tree.path(to: b))
    #expect(pathA.components == [.left])
    #expect(pathB.components == [.right])
  }

  @Test
  func pathToUnknownLeafReturnsNil() {
    let a = PanelID(), ghost = PanelID()
    let tree = SplitTree(leaf: a)
    #expect(tree.path(to: ghost) == nil)
  }

  @Test
  func focusTargetNextWrapsAround() throws {
    let a = PanelID(), b = PanelID(), c = PanelID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .inserting(c, at: b, direction: .right)
    #expect(tree.focusTarget(for: .next, from: a) == b)
    #expect(tree.focusTarget(for: .next, from: b) == c)
    #expect(tree.focusTarget(for: .next, from: c) == a)
    #expect(tree.focusTarget(for: .previous, from: a) == c)
  }

  @Test
  func focusAfterClosingUsesNextForLeftmost() throws {
    let a = PanelID(), b = PanelID(), c = PanelID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .inserting(c, at: b, direction: .right)
    #expect(tree.focusTargetAfterClosing(a) == b)
    #expect(tree.focusTargetAfterClosing(c) == b)
  }

  @Test
  func focusAfterClosingSingletonReturnsNil() {
    let a = PanelID()
    let tree = SplitTree(leaf: a)
    #expect(tree.focusTargetAfterClosing(a) == nil)
  }

  @Test
  func zoomedLeafTracksReplacementAndRemoval() throws {
    let a = PanelID(), b = PanelID(), c = PanelID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .settingZoomed(b)
    #expect(tree.zoomed == b)

    let replaced = try tree.replacing(b, with: c)
    #expect(replaced.zoomed == c)

    let removed = replaced.removing(c)
    #expect(removed.zoomed == nil)
  }

  @Test
  func resizingClampsRatio() throws {
    let a = PanelID(), b = PanelID()
    let tree = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)
    let rootPath = SplitTree<PanelID>.Path()
    let clampedHigh = try tree.resizing(at: rootPath, ratio: 1.5)
    let clampedLow = try tree.resizing(at: rootPath, ratio: -0.2)
    guard case .split(let high) = clampedHigh.root else { Issue.record("Expected split"); return }
    guard case .split(let low) = clampedLow.root else { Issue.record("Expected split"); return }
    #expect(high.ratio == 0.9)
    #expect(low.ratio == 0.1)
  }

  @Test
  func codableRoundTripPreservesStructure() throws {
    let a = PanelID(), b = PanelID(), c = PanelID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .inserting(c, at: b, direction: .down)
      .settingZoomed(b)

    let data = try JSONEncoder().encode(tree)
    let decoded = try JSONDecoder().decode(SplitTree<PanelID>.self, from: data)
    #expect(decoded == tree)
  }
}
