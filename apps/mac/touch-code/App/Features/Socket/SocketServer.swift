import Darwin
import Dispatch
import Foundation
import TouchCodeCore
import TouchCodeIPC
import os

/// Unix-domain-socket listener. Binds the configured path, accepts
/// connections via a `DispatchSourceRead`, and routes each one through a
/// `SocketConnection` actor.
///
/// The accept path uses `DispatchSource.makeReadSource(fileDescriptor:)`
/// over an `O_NONBLOCK` listen socket — so `stop()` can cancel the source
/// and the server tears down without leaving a thread parked in a blocking
/// `accept(2)`. Exec-plan 0003 review (M3.1) replaced the earlier
/// Task.detached while-accept loop.
@MainActor
public final class SocketServer {
  public let path: String
  private let router: MethodRouter
  private let acceptQueue = DispatchQueue(label: "com.touch-code.ipc.accept", qos: .userInitiated)
  private let logger = Logger(subsystem: "com.touch-code.ipc", category: "server")

  private var listenFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var activeConnections: [UUID: Task<Void, Never>] = [:]

  public init(path: String, router: MethodRouter) {
    self.path = path
    self.router = router
  }

  /// Bind + listen. Throws on bind failure.
  public func start() throws {
    try cleanupStaleSocket()

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

    // Narrow the umask around bind(2) so the socket inode is created with
    // mode 0600 from the start — closes the tiny window a same-UID peer
    // could connect through after bind + before chmod. Restore the prior
    // umask immediately.
    let previousMask = umask(0o077)
    let bindResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    umask(previousMask)

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
    // Belt-and-suspenders: umask already got us 0600, but chmod catches
    // unusual mount/filesystem defaults that ignore umask.
    chmod(path, 0o600)
    // Non-blocking so DispatchSource-driven accept() returns EWOULDBLOCK
    // once the backlog is drained.
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    self.listenFD = fd
    logger.info("socket listening at \(self.path, privacy: .public)")

    // Handlers are invoked by libdispatch on `acceptQueue`. Without `@Sendable`,
    // `-default-isolation=MainActor` infers them as MainActor-isolated and the
    // Swift 6 runtime check (`_swift_task_checkIsolatedSwift`) traps the queue
    // callout with `_dispatch_assert_queue_fail`.
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
    source.setEventHandler { @Sendable [weak self] in
      self?.drainAccepts(fd: fd)
    }
    source.setCancelHandler { @Sendable in
      Darwin.close(fd)
    }
    source.activate()
    self.acceptSource = source
  }

  public func stop() {
    if let source = acceptSource {
      source.cancel()  // source's cancel handler closes listenFD
      acceptSource = nil
    } else if listenFD >= 0 {
      Darwin.close(listenFD)
    }
    listenFD = -1
    unlink(path)
    for (_, task) in activeConnections { task.cancel() }
    activeConnections.removeAll()
    logger.info("socket stopped")
  }

  public var connectionCount: Int { activeConnections.count }

  // MARK: - Accept

  nonisolated private func drainAccepts(fd: Int32) {
    while true {
      let client = Darwin.accept(fd, nil, nil)
      if client >= 0 {
        Task { @MainActor [weak self] in
          self?.startConnection(clientFD: client)
        }
        continue
      }
      let err = errno
      if err == EAGAIN || err == EWOULDBLOCK {
        // Backlog drained; wait for the next readable event.
        return
      }
      if err == EINTR {
        continue
      }
      // EBADF (stop closed the fd), ECONNABORTED, or other terminal
      // errors: leave and let the cancel handler clean up.
      return
    }
  }

  @MainActor
  private func startConnection(clientFD: Int32) {
    // M3.1 defense-in-depth: verify the kernel-reported peer UID
    // matches ours before any framing / handshake work runs. The
    // socket file mode (0600 + owner UID) already blocks cross-UID
    // connects at the filesystem level; this closes the TOCTOU tail
    // and covers filesystems that ignore mode bits.
    switch SocketPeerAuth.authorize(fd: clientFD) {
    case .success:
      break
    case .failure(let err):
      logger.warning(
        "peer auth rejected fd \(clientFD, privacy: .public): \(String(describing: err), privacy: .public)")
      Self.shutdownAndClose(fd: clientFD)
      return
    }

    let connectionID = UUID()
    let (stream, continuation) = Self.makeReader()

    let readTask = Task.detached {
      await Self.pumpSocketReads(fd: clientFD, into: continuation)
    }

    let conn = SocketConnection(
      id: connectionID,
      router: router,
      reader: stream,
      write: { data in
        Self.writeAll(fd: clientFD, data: data)
      },
      close: {
        Self.shutdownAndClose(fd: clientFD)
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

  // MARK: - Socket I/O helpers

  private static func makeReader() -> (AsyncStream<Data>, AsyncStream<Data>.Continuation) {
    var continuation: AsyncStream<Data>.Continuation!
    let stream = AsyncStream<Data> { cont in
      continuation = cont
    }
    return (stream, continuation)
  }

  /// Loop-until-complete write. POSIX `write(2)` on a stream socket may
  /// short-write large buffers; silently dropping tail bytes desyncs the
  /// framed wire protocol. Retries on `EINTR` and on short writes; bails
  /// and closes the peer's fd on hard errors.
  nonisolated private static func writeAll(fd: Int32, data: Data) {
    var remaining = data
    while !remaining.isEmpty {
      let written = remaining.withUnsafeBytes { ptr -> Int in
        Darwin.write(fd, ptr.baseAddress, remaining.count)
      }
      if written < 0 {
        if errno == EINTR { continue }
        return
      }
      if written == 0 {
        return
      }
      remaining.removeFirst(written)
    }
  }

  nonisolated private static func shutdownAndClose(fd: Int32) {
    _ = Darwin.shutdown(fd, SHUT_RDWR)
    _ = Darwin.close(fd)
  }

  nonisolated private static func pumpSocketReads(
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
      if n > 0 {
        continuation.yield(Data(buffer.prefix(n)))
        continue
      }
      if n == 0 {
        // Clean EOF from the peer.
        break
      }
      if errno == EINTR {
        continue
      }
      // EBADF / ECONNRESET / other hard error.
      break
    }
    continuation.finish()
  }

  // MARK: - Stale-socket cleanup

  /// Unlink a stale socket at `path`, but only after proving no live
  /// server is currently accepting on it. Probes via `connect(2)`:
  /// `ECONNREFUSED` from a same-UID-readable path means the inode exists
  /// but nothing is accepting, so it's safe to unlink. A successful
  /// connect proves another instance is running; we refuse to start.
  private func cleanupStaleSocket() throws {
    var s = stat()
    guard lstat(path, &s) == 0 else { return }

    let probeFD = socket(AF_UNIX, SOCK_STREAM, 0)
    if probeFD < 0 { return }
    defer { Darwin.close(probeFD) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      throw SocketError.pathTooLong(path)
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          _ = memcpy(dst, src.baseAddress, pathBytes.count)
        }
      }
    }

    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(probeFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connectResult == 0 {
      throw SocketError.alreadyInUse(path: path)
    }
    if errno == ECONNREFUSED || errno == ENOENT {
      unlink(path)
      return
    }
    // Unknown errno; leave the file in place so the caller gets a clean
    // EADDRINUSE from bind rather than stomping on something unexpected.
  }
}

public enum SocketError: Error, Equatable, Sendable {
  case socketCreateFailed(errno: Int32)
  case pathTooLong(String)
  case bindFailed(path: String, errno: Int32)
  case listenFailed(path: String, errno: Int32)
  case alreadyInUse(path: String)
}
