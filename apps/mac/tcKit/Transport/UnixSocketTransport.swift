import Darwin
import Foundation
import os
import TouchCodeIPC

/// Production `Transport` over a Unix domain socket. Opens a fresh
/// connection per `tc` invocation (C4 D10); writes are length-prefix
/// framed per DEC-3.
public final class UnixSocketTransport: Transport, @unchecked Sendable {
  public enum ConnectError: Error, Equatable, Sendable {
    case socketCreateFailed(errno: Int32)
    case pathTooLong(String)
    case connectFailed(path: String, errno: Int32)
  }

  private let fd: Int32
  private let logger = Logger(subsystem: "com.touch-code.cli", category: "transport")
  public let inbound: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private var readTask: Task<Void, Never>?

  public init(path: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 {
      throw ConnectError.socketCreateFailed(errno: errno)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
      throw ConnectError.pathTooLong(path)
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
        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connectResult < 0 {
      let err = errno
      Darwin.close(fd)
      throw ConnectError.connectFailed(path: path, errno: err)
    }

    self.fd = fd
    var continuation: AsyncStream<Data>.Continuation!
    self.inbound = AsyncStream<Data> { cont in continuation = cont }
    self.continuation = continuation
    logger.debug("connected to \(path, privacy: .public)")
    startReader()
  }

  // Follow-up: revisit after a tcKit concurrency audit — the `async` keyword
  // has no `await` body today, but removing it breaks callers. Out of scope
  // for T0, suppressing the lint below to unblock.
  // swiftlint:disable:next async_without_await
  public func send(_ frame: Data) async throws {
    var remaining = frame
    while !remaining.isEmpty {
      let written = remaining.withUnsafeBytes { ptr -> Int in
        Darwin.write(fd, ptr.baseAddress, remaining.count)
      }
      if written < 0 {
        if errno == EINTR { continue }
        throw ConnectError.connectFailed(path: "(write)", errno: errno)
      }
      if written == 0 {
        throw ConnectError.connectFailed(path: "(write=0)", errno: 0)
      }
      remaining.removeFirst(written)
    }
  }

  public func close() {
    readTask?.cancel()
    readTask = nil
    _ = Darwin.shutdown(fd, SHUT_RDWR)
    _ = Darwin.close(fd)
    continuation.finish()
  }

  private func startReader() {
    let fd = self.fd
    let continuation = self.continuation
    readTask = Task.detached {
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
        if n == 0 { break }
        if errno == EINTR { continue }
        break
      }
      continuation.finish()
    }
  }
}
