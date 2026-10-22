import ExtensionFoundation
import Foundation

extension AppExtensionPoint {
    @Definition
    static var herdrPane: AppExtensionPoint { Name("HerdrPane") }
}

// Process lifetime and discovery belong to MainActor. Blocking C ABI calls wait
// only on the original Herdr runner thread, never on the UI actor.
@MainActor
final class HerdrWorkerPool {
    static let shared = HerdrWorkerPool()
    private enum Slot {
        case launching(UUID)
        case connected(UUID, AppExtensionProcess, NSXPCConnection)

        var generation: UUID {
            switch self {
            case .launching(let generation), .connected(let generation, _, _): generation
            }
        }
    }
    private var slots: [String: Slot] = [:]

    func connect() async throws -> NSXPCConnection {
        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .herdrPane)
        for _ in 0..<100 {
            let configured = Bundle.main.object(forInfoDictionaryKey: "HerdrWorkerCount")
            let capacity = (configured as? NSNumber)?.intValue ?? Int(configured as? String ?? "") ?? 0
            if capacity > 0 && slots.count >= capacity {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: [NSLocalizedDescriptionKey: "All Herdr shell workers are in use. Close a pane before opening another."])
            }
            if let identity = monitor.identities.sorted(by: { $0.bundleIdentifier < $1.bundleIdentifier }).first(where: { slots[$0.bundleIdentifier] == nil }) {
                let key = identity.bundleIdentifier
                let generation = UUID()
                slots[key] = .launching(generation)
                do {
                    let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: {
                        Task { @MainActor in
                            guard self.slots[key]?.generation == generation else { return }
                            self.slots.removeValue(forKey: key)
                        }
                    }))
                    guard slots[key]?.generation == generation else {
                        process.invalidate()
                        throw CancellationError()
                    }
                    let connection = try process.makeXPCConnection()
                    connection.exportedInterface = NSXPCInterface(with: TermControlWire.self)
                    connection.exportedObject = TermControlService.shared
                    slots[key] = .connected(generation, process, connection)
                    return connection
                } catch {
                    if slots[key]?.generation == generation { slots.removeValue(forKey: key) }
                    throw error
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT), userInfo: [NSLocalizedDescriptionKey: "Herdr shell worker discovery timed out"])
    }

    func disconnect(_ connection: NSXPCConnection) {
        for (key, slot) in slots {
            guard case .connected(_, let process, let stored) = slot, stored === connection else { continue }
            // Explicit invalidation does not guarantee an interruption callback.
            // Release the reservation in this MainActor transaction; generation
            // checks keep a late callback from removing a replacement process.
            connection.invalidate()
            process.invalidate()
            slots.removeValue(forKey: key)
            return
        }
    }
}

@_cdecl("herdr_extension_disconnect")
func herdrExtensionDisconnect(_ connection: NSXPCConnection) {
    Task { @MainActor in HerdrWorkerPool.shared.disconnect(connection) }
}

@_cdecl("herdr_extension_connect")
func herdrExtensionConnect(_ callback: @escaping @convention(block) (NSXPCConnection?, NSError?) -> Void) {
    Task { @MainActor in
        do { callback(try await HerdrWorkerPool.shared.connect(), nil) }
        catch { callback(nil, error as NSError) }
    }
}
