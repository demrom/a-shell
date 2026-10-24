import Foundation
// Clang exposes ios_system's __thread streams as mutable globals to Swift.
// Capture them only on the command thread before crossing the XPC boundary.
@preconcurrency import ios_system

// Reverse calls use the existing extension XPC connection, with its original
// sandbox/lifetime. No listening port, token or shared-container inbox is added.
enum TermWorker {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var connection: NSXPCConnection?

    static func connect(_ value: NSXPCConnection) {
        lock.lock()
        connection = value
        lock.unlock()
        value.remoteObjectInterface = NSXPCInterface(with: HerdrSpawnBrokerWire.self)
    }

    static func perform(_ request: TermRequest, reply: @escaping (TermResponse) -> Void) {
        lock.lock()
        let value = connection
        lock.unlock()
        guard let value else { reply(.error(503, "host terminal connection is unavailable")); return }
        do {
            let data = try JSONEncoder().encode(request)
            let proxy = value.remoteObjectProxyWithErrorHandler { error in reply(.error(503, error.localizedDescription)) }
            guard let service = proxy as? HerdrSpawnBrokerWire else { reply(.error(503, "host terminal service is unavailable")); return }
            service.terminal(data) { status, data, type in reply(TermResponse(status: status, data: data, contentType: type)) }
        } catch { reply(.error(400, error.localizedDescription)) }
    }
}

@_cdecl("ashell_term")
public func workerTerm(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    guard argc > 0, let argv, !Thread.isMainThread else { return 2 }
    let arguments = (1..<Int(argc)).map { String(cString: argv[$0]!) }
    let output = thread_stdout
    let error = thread_stderr
    return TermCommand.run(arguments, perform: TermWorker.perform, write: { bytes, failed in
        guard let stream = failed ? error : output else { return }
        bytes.withUnsafeBytes { buffer in
            if let address = buffer.baseAddress { _ = fwrite(address, 1, buffer.count, stream) }
        }
        fflush(stream)
    })
}
