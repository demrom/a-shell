import ExtensionFoundation
import Foundation

// Every extension identity compiles this same source and native pane adapter.
@main
final class PaneExtension: AppExtension {
    required init() {}

    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "local.herdr.hostbridge.a-Shell-mini", name: "HerdrPane")
    }

    var configuration: some AppExtensionConfiguration { PaneConfiguration() }
}

struct PaneConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HerdrPaneWire.self)
        TermWorker.connect(connection)
        guard let service = herdr_worker_service() else { return false }
        connection.exportedObject = service
        // ios_system interposes exit/_exit as pthread_exit, which is invalid on
        // this dispatch callback. Process lifetime belongs to ExtensionFoundation.
        connection.invalidationHandler = { service.releasePane() }
        connection.resume()
        return true
    }
}
