import Foundation
import Network
import Security
import CryptoKit
import CNIOBoringSSL

// Use the crypto implementation already linked by the host's NIOSSL dependency.
struct AgentTLS {
    // PKCS#12 needs a nonempty passphrase for Security.framework interoperability.
    // File permissions and iOS data protection secure the persisted private key.
    private static let passphrase = "agents"
    let identity: SecIdentity
    let fingerprint: String
    let newlyCreated: Bool
    let clientCA: SecCertificate

    static func protect(_ file: URL) throws {
        let privateFile = [".agentd-identity.p12", ".agentd-tokens"].contains(file.lastPathComponent)
        guard privateFile || file.lastPathComponent == ".agentd-client-ca.der" else { return }
        var attributes: [FileAttributeKey: Any] = [:]
        if privateFile { attributes[.posixPermissions] = 0o600 }
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        if !attributes.isEmpty { try FileManager.default.setAttributes(attributes, ofItemAtPath: file.path) }
    }

    init(directory: URL) throws {
        // Enroll only the public client CA from the Mac over the trusted USB path.
        // Missing or invalid enrollment must never enable token-only access.
        let clientCAFile = directory.appendingPathComponent(".agentd-client-ca.der")
        try Self.protect(clientCAFile)
        guard let clientCAData = try? Data(contentsOf: clientCAFile),
              let clientCA = SecCertificateCreateWithData(nil, clientCAData as CFData) else {
            throw Self.failure("load enrolled client CA (.agentd-client-ca.der)")
        }
        self.clientCA = clientCA
        let file = directory.appendingPathComponent(".agentd-identity.p12")
        newlyCreated = !FileManager.default.fileExists(atPath: file.path)
        if newlyCreated {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.generate()
            try data.write(to: file, options: .atomic)
        }
        try Self.protect(file)
        let data = try Data(contentsOf: file)
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: Self.passphrase]
        if #available(iOS 18, macOS 15, *) { options[kSecImportToMemoryOnly as String] = true }
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let item = (items as? [[String: Any]])?.first,
              let value = item[kSecImportItemIdentity as String] else { throw Self.failure("load TLS identity", code: Int(status)) }
        identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw Self.failure("read TLS certificate") }
        let der = SecCertificateCopyData(certificate) as Data
        fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        let base64 = der.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 64).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(64, base64.count - offset))
            return String(base64[start..<end])
        }
        let pem = Data(("-----BEGIN CERTIFICATE-----\n" + lines.joined(separator: "\n") + "\n-----END CERTIFICATE-----\n").utf8)
        let publicFile = directory.appendingPathComponent(".agentd-cert.pem")
        if (try? Data(contentsOf: publicFile)) != pem { try pem.write(to: publicFile, options: .atomic) }
    }

    private static func failure(_ operation: String, code: Int = 1) -> NSError {
        NSError(domain: "agents.tls", code: code, userInfo: [NSLocalizedDescriptionKey: "agents: could not \(operation)"])
    }

    private static func generate() throws -> Data {
        guard let key = CNIOBoringSSL_EVP_PKEY_new() else { throw failure("allocate TLS key") }
        defer { CNIOBoringSSL_EVP_PKEY_free(key) }
        guard let ec = CNIOBoringSSL_EC_KEY_new_by_curve_name(NID_X9_62_prime256v1) else { throw failure("allocate TLS curve") }
        defer { CNIOBoringSSL_EC_KEY_free(ec) }
        guard CNIOBoringSSL_EC_KEY_generate_key(ec) == 1, CNIOBoringSSL_EVP_PKEY_set1_EC_KEY(key, ec) == 1 else { throw failure("generate TLS key") }
        guard let cert = CNIOBoringSSL_X509_new() else { throw failure("allocate TLS certificate") }
        defer { CNIOBoringSSL_X509_free(cert) }
        var serial: UInt32 = 0
        guard SecRandomCopyBytes(kSecRandomDefault, MemoryLayout.size(ofValue: serial), &serial) == errSecSuccess,
              CNIOBoringSSL_X509_set_version(cert, 2) == 1,
              CNIOBoringSSL_ASN1_INTEGER_set(CNIOBoringSSL_X509_get_serialNumber(cert), Int(serial) + 1) == 1,
              CNIOBoringSSL_X509_gmtime_adj(CNIOBoringSSL_X509_getm_notBefore(cert), -300) != nil,
              CNIOBoringSSL_X509_gmtime_adj(CNIOBoringSSL_X509_getm_notAfter(cert), 10 * 365 * 86400) != nil,
              CNIOBoringSSL_X509_set_pubkey(cert, key) == 1,
              let name = CNIOBoringSSL_X509_get_subject_name(cert) else { throw failure("initialize TLS certificate") }
        let commonName = Array("agents.local".utf8)
        guard CNIOBoringSSL_X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, commonName, commonName.count, -1, 0) == 1,
              CNIOBoringSSL_X509_set_issuer_name(cert, name) == 1 else { throw failure("name TLS certificate") }
        for (nid, value) in [(NID_subject_alt_name, "DNS:agents.local,DNS:localhost,IP:127.0.0.1"), (NID_basic_constraints, "critical,CA:FALSE"), (NID_ext_key_usage, "serverAuth"), (NID_key_usage, "critical,digitalSignature")] {
            guard let ext = CNIOBoringSSL_X509V3_EXT_nconf_nid(nil, nil, nid, value) else { throw failure("create TLS certificate extension") }
            let result = CNIOBoringSSL_X509_add_ext(cert, ext, -1)
            CNIOBoringSSL_X509_EXTENSION_free(ext)
            guard result == 1 else { throw failure("add TLS certificate extension") }
        }
        guard CNIOBoringSSL_X509_sign(cert, key, CNIOBoringSSL_EVP_sha256()) > 0,
              let p12 = CNIOBoringSSL_PKCS12_create(passphrase, "agents", key, cert, nil, NID_pbe_WithSHA1And3_Key_TripleDES_CBC, NID_pbe_WithSHA1And3_Key_TripleDES_CBC, 0, 0, 0) else { throw failure("sign TLS identity") }
        defer { CNIOBoringSSL_PKCS12_free(p12) }
        let count = CNIOBoringSSL_i2d_PKCS12(p12, nil)
        guard count > 0 else { throw failure("size TLS identity") }
        var result = Data(count: Int(count))
        let written = result.withUnsafeMutableBytes { buffer -> Int32 in
            var pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return CNIOBoringSSL_i2d_PKCS12(p12, &pointer)
        }
        guard written == count else { throw failure("encode TLS identity") }
        return result
    }

    func parameters() throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        guard let local = sec_identity_create(identity) else { throw Self.failure("configure TLS identity") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        let clientCA = self.clientCA
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let evaluation = sec_trust_copy_ref(trust).takeRetainedValue()
            guard SecTrustSetPolicies(evaluation, SecPolicyCreateSSL(false, nil)) == errSecSuccess,
                  SecTrustSetAnchorCertificates(evaluation, [clientCA] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(evaluation, true) == errSecSuccess,
                  SecTrustSetNetworkFetchAllowed(evaluation, false) == errSecSuccess else {
                complete(false)
                return
            }
            complete(SecTrustEvaluateWithError(evaluation, nil))
        }, DispatchQueue(label: "agents.tls.verify"))
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}

// HTTP wire behavior follows mansion/_system/scripts/agentd.py.
final class AgentServer {
    struct Client {
        let name: String
        let token: String
        let home: String
    }
    struct Reply {
        let status: Int
        var body: Data
        var headers: [String: String] = [:]
        var sent: (() -> Void)?
        init(_ status: Int, _ text: String, headers: [String: String] = [:]) {
            self.status = status
            self.body = Data(text.utf8)
            self.headers = headers
        }
        init(_ status: Int, data: Data, headers: [String: String] = [:]) {
            self.status = status
            self.body = data
            self.headers = headers
        }
    }
    private final class Job {
        let id: Int
        let command: String
        let cwd: String
        let owner: String
        let started = Date()
        var state = "queued"
        var code = 0
        var output = Data()
        var waiters: [UUID: (Reply) -> Void] = [:]
        init(_ id: Int, _ command: String, _ cwd: String, _ owner: String) {
            self.id = id; self.command = command; self.cwd = cwd; self.owner = owner
        }
        var line: String { "\(id)\t\(owner)\t\(state)\t\(Int(-started.timeIntervalSinceNow))s\t\(cwd)\t\(command)" }
    }
    let root: String
    let clients: [Client]
    let tls: AgentTLS
    private let credentialDirectory: URL
    private let execute: (String, String) -> (Int, Data)
    private let terminal: (String, Data, @escaping (Reply) -> Void) -> Void
    private let queue = DispatchQueue(label: "agents.http")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var receiving: Set<UUID> = []
    private var jobs: [Job] = []
    private var nextID = 1
    private var current: Job?

    init(root: String, tokensFile: URL, execute: @escaping (String, String) -> (Int, Data), terminal: @escaping (String, Data, @escaping (Reply) -> Void) -> Void) throws {
        self.root = root
        self.execute = execute
        self.terminal = terminal
        credentialDirectory = tokensFile.deletingLastPathComponent()
        tls = try AgentTLS(directory: tokensFile.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: tokensFile.path) {
            var lines = ["# name token [home]; a client with a home is fenced into it"]
            for (name, home) in [("master", ""), ("mansion", "."), ("herdr", "~/Documents/herdr")] {
                var bytes = [UInt8](repeating: 0, count: 16)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                lines.append("\(name) \(token) \(home)")
            }
            try FileManager.default.createDirectory(at: tokensFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: tokensFile, atomically: true, encoding: .utf8)
        }
        try AgentTLS.protect(tokensFile)
        var loaded: [Client] = []
        for line in try String(contentsOf: tokensFile, encoding: .utf8).components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let name = parts.first, !name.hasPrefix("#") else { continue }
            guard parts.count >= 2 else { throw NSError(domain: "agents.tokens", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid .agentd-tokens line"] ) }
            let home = parts.count > 2 ? Self.path(parts[2], base: root) : ""
            if !home.isEmpty { try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true) }
            loaded.append(Client(name: name, token: parts[1], home: home.isEmpty ? "" : Self.real(home)))
        }
        guard !loaded.isEmpty else { throw NSError(domain: "agents.tokens", code: 2, userInfo: [NSLocalizedDescriptionKey: "No clients in .agentd-tokens"]) }
        clients = loaded
    }

    func start(port: UInt16 = 8765, ready: @escaping (Result<UInt16, Error>) -> Void) throws {
        let listener = try NWListener(using: tls.parameters(), on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready(.success(listener.port!.rawValue))
            case .failed(let error): ready(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            self.receiving.insert(id)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.connections.removeValue(forKey: id)
                    self?.receiving.remove(id)
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
            self.queue.asyncAfter(deadline: .now() + 15) { [weak self, weak connection] in
                // Only incomplete HTTP requests retain the receive deadline.
                if self?.receiving.contains(id) == true { connection?.cancel() }
            }
        }
        listener.start(queue: queue)
    }

    func stop(_ stopped: @escaping () -> Void = {}) {
        queue.async {
            let listener = self.listener
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
            self.receiving.removeAll()
            for job in self.jobs where job.state == "queued" || job.state == "running" {
                job.state = "abandoned"
                self.notify(job)
            }
            self.current = nil
            guard let listener else { stopped(); return }
            switch listener.state {
            case .cancelled, .failed: stopped()
            default:
                listener.stateUpdateHandler = { state in
                    if case .cancelled = state { stopped() }
                }
                listener.cancel()
            }
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, ended, error in
            guard let self else { connection.cancel(); return }
            var data = accumulated
            if let bytes { data.append(bytes) }
            guard data.count <= 64 * 1024 * 1024 else { self.send(connection, Reply(413, "request too large\n")); return }
            if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                guard end.lowerBound <= 65536,
                      let header = String(data: data[..<end.lowerBound], encoding: .isoLatin1) else {
                    self.send(connection, Reply(400, "invalid headers\n")); return
                }
                let lines = header.components(separatedBy: "\r\n")
                let request = lines[0].split(separator: " ").map(String.init)
                guard request.count == 3 else { self.send(connection, Reply(400, "invalid request\n")); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { self.send(connection, Reply(400, "invalid header\n")); return }
                    let key = line[..<colon].lowercased()
                    guard headers[key] == nil else { self.send(connection, Reply(400, "duplicate header\n")); return }
                    headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard headers["transfer-encoding"] == nil,
                      let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 64 * 1024 * 1024 else {
                    self.send(connection, Reply(400, "Content-Length expected\n")); return
                }
                if data.count - end.upperBound >= length {
                    // Parsed requests may wait X-Timeout; cancel only on stop or peer failure.
                    if let id = self.connections.first(where: { $0.value === connection })?.key { self.receiving.remove(id) }
                    self.route(request[0], request[1], headers, Data(data[end.upperBound..<(end.upperBound + length)])) { reply in
                        self.queue.async { self.send(connection, reply) }
                    }
                    return
                }
            } else if data.count > 65536 {
                self.send(connection, Reply(431, "headers too large\n")); return
            }
            if ended || error != nil { connection.cancel(); return }
            self.receive(connection, accumulated: data)
        }
    }

    private func send(_ connection: NWConnection, _ reply: Reply) {
        var header = "HTTP/1.1 \(reply.status) \(HTTPURLResponse.localizedString(forStatusCode: reply.status))\r\nContent-Length: \(reply.body.count)\r\nContent-Type: \(reply.headers["Content-Type"] ?? "text/plain; charset=utf-8")\r\nConnection: close\r\n"
        for (name, value) in reply.headers where name != "Content-Type" { header += "\(name): \(value)\r\n" }
        var data = Data((header + "\r\n").utf8)
        data.append(reply.body)
        connection.send(content: data, completion: .contentProcessed { error in
            connection.cancel()
            if error == nil { reply.sent?() }
        })
    }

    private static func real(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    private static func path(_ path: String, base: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : (base as NSString).appendingPathComponent(expanded)
    }
    private func authorized(_ token: String) -> Client? {
        clients.first { client in
            let expected = Array(client.token.utf8), given = Array(token.utf8)
            var difference = expected.count ^ given.count
            for index in expected.indices { difference |= Int(expected[index] ^ (index < given.count ? given[index] : 0)) }
            return difference == 0
        }
    }
    private func route(_ method: String, _ target: String, _ headers: [String: String], _ body: Data, reply: @escaping (Reply) -> Void) {
        guard let client = authorized(headers["x-token"] ?? "") else { reply(Reply(401, "bad token\n")); return }
        guard let url = URLComponents(string: target) else { reply(Reply(400, "invalid target\n")); return }
        let query = url.queryItems ?? []
        let cwd = Self.path((headers["x-cwd"] ?? "").removingPercentEncoding ?? "", base: client.home.isEmpty ? root : client.home)
        let file = Self.path(query.first(where: { $0.name == "path" })?.value ?? "", base: cwd)
        func fenced(_ path: String) -> Bool {
            let real = Self.real(path)
            if client.home.isEmpty || real == client.home || real.hasPrefix(client.home + "/") { return false }
            reply(Reply(403, "\(client.name) is fenced into \(client.home): \(real)\n"))
            return true
        }
        switch (method, url.path) {
        case ("GET", "/"):
            if !fenced(cwd) { reply(Reply(200, "\(cwd)\nclient: \(client.name)\n")) }
        case ("POST", "/restart"):
            terminal(url.path, body, reply)
        case ("GET", "/windows"), ("GET", "/panes"), ("GET", "/screen"), ("GET", "/scrollback"), ("GET", "/size"), ("GET", "/cursor"), ("GET", "/state"), ("GET", "/shot"), ("POST", "/type"), ("POST", "/keys"), ("POST", "/paste"), ("POST", "/wait"), ("POST", "/resize"), ("POST", "/clear"):
            terminal(target, body, reply)
        case ("GET", "/file"):
            guard !fenced(file) else { return }
            do { reply(Reply(200, data: try Data(contentsOf: URL(fileURLWithPath: file)))) }
            catch { reply(Reply(404, "\(error.localizedDescription)\n")) }
        case ("PUT", "/file"):
            guard query.contains(where: { $0.name == "path" && !($0.value ?? "").isEmpty }) else { reply(Reply(404, "use PUT /file?path=...\n")); return }
            guard !fenced(file) else { return }
            do {
                let destination = URL(fileURLWithPath: file)
                let credential = Self.real(destination.deletingLastPathComponent().path) == Self.real(credentialDirectory.path)
                    && [".agentd-identity.p12", ".agentd-tokens", ".agentd-client-ca.der"].contains(destination.lastPathComponent)
                try body.write(to: destination, options: credential ? .atomic : [])
                if credential {
                    try AgentTLS.protect(destination)
                }
                reply(Reply(200, "written\n"))
            }
            catch { reply(Reply(500, "\(error.localizedDescription)\n")) }
        case ("POST", "/run"):
            guard !fenced(cwd) else { return }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue else { reply(Reply(400, "X-Cwd: not a directory: \(cwd)\n")); return }
            guard let timeout = Double(headers["x-timeout"] ?? "300"), timeout.isFinite else { reply(Reply(400, "X-Timeout: seconds expected\n")); return }
            guard let command = String(data: body, encoding: .utf8) else { reply(Reply(400, "UTF-8 command expected\n")); return }
            let job = Job(nextID, command, cwd, client.name)
            nextID += 1
            jobs.append(job)
            for old in jobs.dropLast(20) where old.state == "done" || old.state == "abandoned" { jobs.removeAll { $0 === old } }
            let waiter = UUID()
            job.waiters[waiter] = reply
            startNext()
            queue.asyncAfter(deadline: .now() + max(0, min(timeout, 86400))) {
                if let callback = job.waiters.removeValue(forKey: waiter) { callback(self.result(job)) }
            }
        case ("GET", "/jobs"):
            reply(Reply(200, jobs.map { $0.line + "\n" }.joined()))
        case ("GET", "/job"), ("POST", "/abandon"):
            guard let id = Int(query.first(where: { $0.name == "id" })?.value ?? ""), let job = jobs.first(where: { $0.id == id }) else { reply(Reply(404, "no such job; GET /jobs lists them\n")); return }
            if method == "GET" { reply(result(job)); return }
            guard client.home.isEmpty || job.owner == client.name else { reply(Reply(403, "\(client.name) is fenced and cannot abandon \(job.owner)'s job\n")); return }
            guard job.state == "running" || job.state == "queued" else { reply(Reply(409, job.line + "\n")); return }
            job.state = "abandoned"
            if current === job { current = nil }
            notify(job)
            reply(Reply(200, job.line + "\n"))
            startNext()
        default: reply(Reply(404, "unknown route\n"))
        }
    }
    private func result(_ job: Job) -> Reply {
        let headers = ["X-Job": String(job.id)]
        if job.state == "done" { return Reply(200, data: job.output, headers: headers.merging(["X-Exit-Code": String(job.code)]) { _, new in new }) }
        if job.state == "abandoned" { return Reply(410, "job \(job.id) was abandoned\n", headers: headers) }
        let ahead = current == nil || current === job ? "" : "; waiting behind job \(current!.id): \(current!.command)"
        return Reply(504, "job \(job.id) \(job.state) for \(Int(-job.started.timeIntervalSinceNow))s\(ahead)\nGET /job?id=\(job.id) for the result, POST /abandon?id=\(job.id) if it hangs\n", headers: headers)
    }
    private func notify(_ job: Job) {
        let callbacks = job.waiters.values
        job.waiters.removeAll()
        for callback in callbacks { callback(result(job)) }
    }
    private func startNext() {
        guard current == nil, listener != nil, let job = jobs.first(where: { $0.state == "queued" }) else { return }
        current = job
        job.state = "running"
        DispatchQueue.global(qos: .utility).async {
            let (code, output) = self.execute(job.command, job.cwd)
            self.queue.async {
                job.code = code; job.output = output
                guard job.state != "abandoned" else { return }
                job.state = "done"
                if self.current === job { self.current = nil }
                self.notify(job)
                self.startNext()
            }
        }
    }
}
