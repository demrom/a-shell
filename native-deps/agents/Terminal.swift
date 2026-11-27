import UIKit
import SwiftTerm
import ios_system

// All terminal access stays on the same main thread as human keyboard input.
final class AgentsTerminal {
    static let shared = AgentsTerminal()
    private var server: AgentServer?
    private var banner: UILabel?
    private var activationObserver: NSObjectProtocol?
    private var announcedCertificate = false
    var running: Bool { server != nil }

    func commandWhenActive(_ argument: String) {
        if argument.isEmpty {
            command(argument, scene: scene())
            return
        }
        if let scene = scene(), scene.terminalView != nil {
            command(argument, scene: scene)
            return
        }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let observer = self.activationObserver { NotificationCenter.default.removeObserver(observer) }
            self.activationObserver = nil
            self.commandWhenActive(argument)
        }
    }

    private func scene() -> SceneDelegate? {
        TermTerminal.shared.scene()
    }

    func command(_ argument: String, scene: SceneDelegate?) {
        if argument == "reload" { reload(); return }
        if argument == "off" { stop(); scene?.terminalView?.feed(text: "agents stopped\r\n"); return }
        if argument == "tokens" {
            guard let server else { scene?.terminalView?.feed(text: "agents: start the bridge first\r\n"); return }
            for client in server.clients { scene?.terminalView?.feed(text: "token \(client.name): \(client.token)\r\n") }
            return
        }
        guard argument.isEmpty else { scene?.terminalView?.feed(text: "usage: agents [off|tokens|reload]\r\n"); return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let server {
            // Older managed profiles remove this marker before invoking agents.
            try? "agentd running\n".write(to: documents.appendingPathComponent("agentd-running"), atomically: true, encoding: .utf8)
            if let scene { announce(server, scene: scene); showBanner(scene) }
            return
        }
        let bookmarks = UserDefaults.standard.dictionary(forKey: "bookmarkNames") ?? [:]
        let vault = bookmarks["mansion"] as? String
        let root = vault.flatMap { FileManager.default.isReadableFile(atPath: $0) ? $0 : nil } ?? documents.path
        do {
            let server = try AgentServer(root: root, tokensFile: documents.appendingPathComponent(".agentd-tokens"), execute: Self.execute) { route, body, reply in
                DispatchQueue.main.async { self.terminal(route, body, reply: reply) }
            }
            self.server = server
            try server.start { result in
                DispatchQueue.main.async {
                    guard self.server === server else { return }
                    switch result {
                    case .success: self.presentWhenActive(server)
                    case .failure(let error): self.stop(); scene?.terminalView?.feed(text: "agents: \(error.localizedDescription)\r\n")
                    }
                }
            }
            try "agentd running\n".write(to: documents.appendingPathComponent("agentd-running"), atomically: true, encoding: .utf8)
        } catch { stop(); scene?.terminalView?.feed(text: "agents: \(error.localizedDescription)\r\n") }
    }

    private func presentWhenActive(_ server: AgentServer) {
        guard self.server === server else { return }
        if let scene = scene(), scene.terminalView != nil {
            announce(server, scene: scene)
            showBanner(scene)
            return
        }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self, weak server] _ in
            guard let self, let server else { return }
            if let observer = self.activationObserver { NotificationCenter.default.removeObserver(observer) }
            self.activationObserver = nil
            self.presentWhenActive(server)
        }
    }

    private func reload() {
        stop { self.command("", scene: self.scene()) }
    }

    func stop(_ stopped: @escaping () -> Void = {}) {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        let previous = server
        server = nil
        banner?.removeFromSuperview()
        banner = nil
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: documents.appendingPathComponent("agentd-running"))
        if let previous { previous.stop { DispatchQueue.main.async(execute: stopped) } }
        else { stopped() }
    }

    private func announce(_ server: AgentServer, scene: SceneDelegate) {
        // Profile re-entry must not overwrite a TUI or send it printPrompt's newline.
        guard scene.currentCommand.isEmpty else { return }
        var address = "127.0.0.1"
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0, let first = interfaces {
            var entry: UnsafeMutablePointer<ifaddrs>? = first
            while let current = entry {
                let interface = current.pointee
                if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: interface.ifa_name) == "en0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { address = String(cString: host) }
                }
                entry = interface.ifa_next
            }
            freeifaddrs(first)
        }
        let home = NSHomeDirectory()
        let root = server.root.hasPrefix(home + "/") ? "~" + String(server.root.dropFirst(home.count)) : String(cString: ios_getBookmarkedVersion(server.root.utf8CString))
        var text = "\r\nagentd on https://agents.local:8765\r\naddress=\(address)\r\nroot=\(root)\r\ntokens: ~/Documents/.agentd-tokens\r\ncert: ~/Documents/.agentd-cert.pem\r\n"
        if server.tls.newlyCreated && !announcedCertificate {
            text += "certificate SHA256: \(server.tls.fingerprint)\r\n"
            announcedCertificate = true
        }
        text += "agents off or Return at an empty shell prompt to stop\r\n"
        scene.terminalView?.feed(text: text)
        scene.printPrompt()
    }

    private func showBanner(_ scene: SceneDelegate) {
        guard let window = scene.terminalView?.window else { return }
        banner?.removeFromSuperview()
        let label = UILabel()
        label.text = "  agents serving :8765  "
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = .systemIndigo
        label.layer.cornerRadius = 6
        label.clipsToBounds = true
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -8)
        ])
        banner = label
    }

    private func terminal(_ route: String, _ body: Data, reply: @escaping (AgentServer.Reply) -> Void) {
        if route == "/restart" {
            var response = AgentServer.Reply(200, "restarting\n")
            response.sent = { DispatchQueue.main.async { self.reload() } }
            reply(response)
            return
        }
        do {
            let request = try TermRequest.http(route, body: body)
            TermTerminal.shared.perform(request) { result in
                reply(.init(result.status, data: result.data, headers: ["Content-Type": result.contentType]))
            }
        } catch { reply(.init(400, "\(error.localizedDescription)\n")) }
    }

    private static func execute(_ command: String, cwd: String) -> (Int, Data) {
        guard let session = strdup(UUID().uuidString), let input = fopen("/dev/null", "r"), let output = tmpfile() else { return (-1, Data("agents: could not open command streams\n".utf8)) }
        defer {
            // Dispatch workers are reused; never retain pointers to this closed request.
            thread_stdin = nil
            thread_stdout = nil
            thread_stderr = nil
            thread_context = nil
            ios_closeSession(session); free(session); fclose(input); fclose(output)
        }
        // ios_setStreams updates session state, while ios_system only fills nil TLS.
        thread_stdin = nil
        thread_stdout = nil
        thread_stderr = nil
        thread_context = nil
        ios_switchSession(session)
        ios_setContext(session)
        ios_setStreams(input, output, output)
        ios_settty(nil)
        ios_setDirectoryURL(URL(fileURLWithPath: cwd))
        let pid = ios_fork()
        guard pid > 0 else { return (-1, Data("Cannot start command: process table full\n".utf8)) }
        ios_system(command.decomposedStringWithCanonicalMapping)
        ios_waitpid(pid)
        let code = ios_getCommandStatus()
        ios_releaseThreadId(pid)
        fflush(output)
        rewind(output)
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = fread(&bytes, 1, bytes.count, output)
            if count == 0 { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return (Int(code), result)
    }
}

@_cdecl("ashell_agents")
public func ashellAgents(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    let argument = argc > 1 ? String(cString: argv![1]!) : ""
    DispatchQueue.main.async {
        AgentsTerminal.shared.commandWhenActive(argument)
    }
    return 0
}
