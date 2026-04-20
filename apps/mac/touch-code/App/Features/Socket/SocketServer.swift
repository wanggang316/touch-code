import Darwin
import Foundation
import os
import TouchCodeCore
import TouchCodeIPC

/// Unix-domain-socket listener. Binds the configured path, accepts
/// connections, and routes each one through a `SocketConnection` actor.
///
/// Peer authentication (`LOCAL_PEERCRED`) and the per-connection bounded
/// in-flight queue (DEC-9) land with M3.1; M3 ships a correct-but-basic
/// accept loop that unblocks `tc`'s round-trip path end-to-end.
@MainActor
public final class SocketServer {
  public let path: String
  private let router: MethodRouter
  private let logger = Logger(subsystem: "com.touch-code.ipc", category: "server")

  private var listenFD: Int32 = -1
  private var acceptTask: Task<Void, Never>?
  private var activeConnections: [UUID: Task<Void, Never>] = [:]

  public init(path: String, router: MethodRouter) {
    self.path = path
    self.router = router
  }

  /// Bind + listen. Throws on bind failure.
  public func start() throws {
    cleanupStaleSocket()

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 {
      throw SocketError.socketCreateFailed(errno: errno)
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
      throw SocketError.pathTooLong(path)
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          _ = memcpy(dst, src.baseAddress, pathBytes.count)
        }
      }
    }
    let bindResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if bindResult < 0 {
      let err = errno
      Darwin.close(fd)
      throw SocketError.bindFailed(path: path, errno: err)
    }
    if Darwin.listen(fd, 64) < 0 {
      let err = errno
      Darwin.close(fd)
      throw SocketError.listenFailed(path: path, errno: err)
    }
    chmod(path, 0o600)

    self.listenFD = fd
    logger.info("socket listening at \(self.path, privacy: .public)")
    acceptTask = Task.detached { [weak self] in await self?.acceptLoop(fd: fd) }
  }

  public func stop() {
    acceptTask?.cancel()
    acceptTask = nil
    if listenFD >= 0 {
      Darwin.close(listenFD)
      listenFD = -1
    }
    unlink(path)
    for (_, task) in activeConnections { task.cancel() }
    activeConnections.removeAll()
    logger.info("socket stopped")
  }

  public var connectionCount: Int { activeConnections.count }

  // MARK: - Accept loop

  private func acceptLoop(fd: Int32) async {
    while !Task.isCancelled {
      let client = Darwin.accept(fd, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        break
      }
      await MainActor.run { self.startConnection(fd: client) }
    }
  }

  private func startConnection(clientFD: Int32) {
    let connectionID = UUID()
    let (stream, continuation) = Self.makeReader()

    // Start the socket-read pump that yields Data into the stream.
    let readTask = Task.detached {
      await Self.pumpSocketReads(fd: clientFD, into: continuation)
    }

    let conn = SocketConnection(
      id: connectionID,
      router: router,
      reader: stream,
      write: { data in
        _ = data.withUnsafeBytes { ptr in
          Darwin.write(clientFD, ptr.baseAddress, data.count)
        }
      },
      close: {
        Darwin.close(clientFD)
      }
    )

    let serveTask = Task.detached { [weak self] in
      await conn.serve()
      readTask.cancel()
      if let self {
        await self.removeConnection(id: connectionID)
      }
    }
    activeConnections[connectionID] = serveTask
  }

  private func removeConnection(id: UUID) {
    activeConnections[id] = nil
  }

  // `startConnection(fd:)` alias retained for call-site compatibility with
  // the earlier draft; new code should use `startConnection(clientFD:)`.
  private func startConnection(fd: Int32) { startConnection(clientFD: fd) }

  private static func makeReader() -> (AsyncStream<Data>, AsyncStream<Data>.Continuation) {
    var continuation: AsyncStream<Data>.Continuation!
    let stream = AsyncStream<Data> { cont in
      continuation = cont
    }
    return (stream, continuation)
  }

  private static func pumpSocketReads(
    fd: Int32,
    into continuation: AsyncStream<Data>.Continuation
  ) async {
    let bufferSize = 8192
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while !Task.isCancelled {
      await Task.yield()
      let n = buffer.withUnsafeMutableBufferPointer { ptr in
        Darwin.read(fd, ptr.baseAddress, bufferSize)
      }
      if n <= 0 { break }
      continuation.yield(Data(buffer.prefix(n)))
    }
    continuation.finish()
  }

  // MARK: - Helpers

  private func cleanupStaleSocket() {
    var s = stat()
    if lstat(path, &s) == 0 {
      unlink(path)
    }
  }
}

public enum SocketError: Error, Equatable, Sendable {
  case socketCreateFailed(errno: Int32)
  case pathTooLong(String)
  case bindFailed(path: String, errno: Int32)
  case listenFailed(path: String, errno: Int32)
}
