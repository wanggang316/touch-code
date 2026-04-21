import Foundation

public nonisolated struct SplitTree<Leaf: Hashable & Codable & Sendable>: Equatable, Codable, Sendable {
  public let root: Node?
  public let zoomed: Leaf?

  public init() { self.init(root: nil, zoomed: nil) }
  public init(leaf: Leaf) { self.init(root: .leaf(leaf), zoomed: nil) }
  public init(root: Node?, zoomed: Leaf? = nil) {
    self.root = root
    self.zoomed = root.flatMap { r in zoomed.flatMap { r.contains($0) ? $0 : nil } }
  }

  public var isEmpty: Bool { root == nil }
  public var isSplit: Bool { if case .split = root { true } else { false } }

  public indirect enum Node: Equatable, Codable, Sendable {
    case leaf(Leaf)
    case split(Split)
  }

  public struct Split: Equatable, Codable, Sendable {
    public let direction: Direction
    public let ratio: Double
    public let left: Node
    public let right: Node

    public init(direction: Direction, ratio: Double, left: Node, right: Node) {
      self.direction = direction
      self.ratio = ratio
      self.left = left
      self.right = right
    }
  }

  public enum Direction: String, Codable, Sendable { case horizontal, vertical }

  public enum NewDirection: String, Codable, Sendable { case left, right, up, down }

  public enum PathComponent: String, Codable, Sendable { case left, right }

  public struct Path: Equatable, Codable, Sendable {
    public let components: [PathComponent]
    public var isEmpty: Bool { components.isEmpty }
    public init(_ components: [PathComponent] = []) { self.components = components }
  }

  public enum FocusDirection: Sendable { case previous, next }

  public enum SplitError: Error, Equatable { case leafNotFound }

  // MARK: - Inspection

  public func leaves() -> [Leaf] { root?.leaves() ?? [] }

  public func contains(_ leaf: Leaf) -> Bool { root?.contains(leaf) ?? false }

  public func path(to leaf: Leaf) -> Path? { root?.path(to: leaf) }

  // MARK: - Mutation

  public func inserting(_ leaf: Leaf, at anchor: Leaf, direction: NewDirection) throws -> Self {
    guard let root else { throw SplitError.leafNotFound }
    guard let path = root.path(to: anchor) else { throw SplitError.leafNotFound }

    let (splitDirection, newOnLeft): (Direction, Bool) =
      switch direction {
      case .left: (.horizontal, true)
      case .right: (.horizontal, false)
      case .up: (.vertical, true)
      case .down: (.vertical, false)
      }

    let newNode: Node = .leaf(leaf)
    let anchorNode: Node = .leaf(anchor)
    let newSplit: Node = .split(
      Split(
        direction: splitDirection,
        ratio: 0.5,
        left: newOnLeft ? newNode : anchorNode,
        right: newOnLeft ? anchorNode : newNode
      ))
    let newRoot = try root.replacing(at: path, with: newSplit)
    return Self(root: newRoot, zoomed: zoomed)
  }

  public func removing(_ leaf: Leaf) -> Self {
    guard let root else { return self }
    let newRoot = root.removing(.leaf(leaf))
    let newZoomed = (zoomed == leaf) ? nil : zoomed
    return Self(root: newRoot, zoomed: newZoomed)
  }

  public func replacing(_ old: Leaf, with new: Leaf) throws -> Self {
    guard let root else { throw SplitError.leafNotFound }
    guard let path = root.path(to: old) else { throw SplitError.leafNotFound }
    let newRoot = try root.replacing(at: path, with: .leaf(new))
    let newZoomed: Leaf? = (zoomed == old) ? new : zoomed
    return Self(root: newRoot, zoomed: newZoomed)
  }

  public func settingZoomed(_ leaf: Leaf?) -> Self {
    Self(root: root, zoomed: leaf)
  }

  public func resizing(at path: Path, ratio: Double) throws -> Self {
    guard let root else { throw SplitError.leafNotFound }
    let clamped = max(0.1, min(0.9, ratio))
    guard case .split(let split) = root.node(at: path) else { throw SplitError.leafNotFound }
    let newSplit: Node = .split(
      Split(
        direction: split.direction,
        ratio: clamped,
        left: split.left,
        right: split.right
      ))
    let newRoot = try root.replacing(at: path, with: newSplit)
    return Self(root: newRoot, zoomed: zoomed)
  }

  // MARK: - Focus

  public func focusTarget(for direction: FocusDirection, from leaf: Leaf) -> Leaf? {
    guard let root, root.contains(leaf) else { return nil }
    let all = root.leaves()
    guard let index = all.firstIndex(of: leaf) else { return nil }
    let next: Int =
      switch direction {
      case .previous: (index - 1 + all.count) % all.count
      case .next: (index + 1) % all.count
      }
    return all[next]
  }

  public func focusTargetAfterClosing(_ leaf: Leaf) -> Leaf? {
    guard let root, root.contains(leaf) else { return nil }
    let all = root.leaves()
    guard all.count > 1 else { return nil }
    // Match Ghostty's controller: closing the leftmost leaf moves to the next; otherwise to the previous.
    if all.first == leaf {
      return focusTarget(for: .next, from: leaf)
    } else {
      return focusTarget(for: .previous, from: leaf)
    }
  }
}

// MARK: - Node recursion

extension SplitTree.Node {
  public func leaves() -> [Leaf] {
    switch self {
    case .leaf(let leaf): return [leaf]
    case .split(let split): return split.left.leaves() + split.right.leaves()
    }
  }

  public func contains(_ leaf: Leaf) -> Bool {
    switch self {
    case .leaf(let l): return l == leaf
    case .split(let split): return split.left.contains(leaf) || split.right.contains(leaf)
    }
  }

  public func path(to leaf: Leaf) -> SplitTree<Leaf>.Path? {
    var components: [SplitTree<Leaf>.PathComponent] = []
    func search(_ node: SplitTree<Leaf>.Node) -> Bool {
      switch node {
      case .leaf(let l): return l == leaf
      case .split(let split):
        components.append(.left)
        if search(split.left) { return true }
        components.removeLast()
        components.append(.right)
        if search(split.right) { return true }
        components.removeLast()
        return false
      }
    }
    return search(self) ? SplitTree<Leaf>.Path(components) : nil
  }

  public func node(at path: SplitTree<Leaf>.Path) -> SplitTree<Leaf>.Node? {
    if path.isEmpty { return self }
    guard case .split(let split) = self else { return nil }
    let rest = SplitTree<Leaf>.Path(Array(path.components.dropFirst()))
    switch path.components[0] {
    case .left: return split.left.node(at: rest)
    case .right: return split.right.node(at: rest)
    }
  }

  public func replacing(
    at path: SplitTree<Leaf>.Path,
    with newNode: SplitTree<Leaf>.Node
  ) throws -> SplitTree<Leaf>.Node {
    if path.isEmpty { return newNode }
    guard case .split(let split) = self else { throw SplitTree<Leaf>.SplitError.leafNotFound }
    let rest = SplitTree<Leaf>.Path(Array(path.components.dropFirst()))
    switch path.components[0] {
    case .left:
      let newLeft = try split.left.replacing(at: rest, with: newNode)
      return .split(
        SplitTree<Leaf>.Split(
          direction: split.direction, ratio: split.ratio, left: newLeft, right: split.right
        ))
    case .right:
      let newRight = try split.right.replacing(at: rest, with: newNode)
      return .split(
        SplitTree<Leaf>.Split(
          direction: split.direction, ratio: split.ratio, left: split.left, right: newRight
        ))
    }
  }

  public func removing(_ target: SplitTree<Leaf>.Node) -> SplitTree<Leaf>.Node? {
    if self == target { return nil }
    switch self {
    case .leaf:
      return self
    case .split(let split):
      let newLeft = split.left.removing(target)
      let newRight = split.right.removing(target)
      switch (newLeft, newRight) {
      case (nil, nil): return nil
      case (nil, let r?): return r
      case (let l?, nil): return l
      case (let l?, let r?):
        return .split(SplitTree<Leaf>.Split(direction: split.direction, ratio: split.ratio, left: l, right: r))
      }
    }
  }
}
