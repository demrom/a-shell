import Foundation

#if HERDR_EMBEDDED
@_silgen_name("herdr_ios_terminal_json")
private func herdrTerminalJSON(_ input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("herdr_ios_terminal_free")
private func herdrTerminalFree(_ value: UnsafeMutablePointer<CChar>)
#endif

enum TermPane {
    static func perform(_ request: TermRequest, reply: @escaping (TermResponse) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            #if HERDR_EMBEDDED
            do {
                func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
                    let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params])
                    let text = String(decoding: data, as: UTF8.self)
                    guard let pointer = text.withCString({ herdrTerminalJSON($0) }) else { throw TermRequest.Invalid("Herdr returned no terminal response") }
                    defer { herdrTerminalFree(pointer) }
                    let value = try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any] ?? [:]
                    if let error = value["error"] as? [String: Any] {
                        if error["code"] as? String == "timeout" { throw PaneTimeout() }
                        throw TermRequest.Invalid(error["message"] as? String ?? "Herdr terminal request failed")
                    }
                    guard let result = value["result"] as? [String: Any] else { throw TermRequest.Invalid("invalid Herdr terminal response") }
                    return result
                }
                if request.verb == "panes" { reply(TermResponse(try call("pane.list", [:]))); return }
                guard let pane = request.pane else { throw TermRequest.Invalid("select --pane ID from term panes") }
                var params: [String: Any] = ["pane": pane, "verb": request.verb, "keys": request.keys.map { key in
                    ["ctrl-c": "ctrl+c", "pgdn": "pagedown", "pgup": "pageup", "esc": "escape"][key.lowercased()] ?? key
                }]
                if let text = request.text { params["text"] = text }
                if let bytes = request.bytes { params["bytes"] = Array(bytes) }
                if let lines = request.lines { params["lines"] = lines }
                if let cols = request.columns { params["columns"] = cols }
                if let rows = request.rows { params["height"] = rows }
                if request.verb == "wait" {
                    _ = try call("pane.wait_for_output", ["pane_id": pane, "source": "visible", "match": ["type": "regex", "value": request.text ?? ""], "timeout_ms": Int(request.timeout * 1000)])
                    params["verb"] = "screen"
                }
                if request.verb == "type" {
                    let delays = request.delays.isEmpty ? Array(repeating: 0, count: request.keys.count) : request.delays
                    guard delays.count == request.keys.count, request.keys.count <= 256, delays.allSatisfy({ (0...2000).contains($0) }), delays.reduce(0, +) <= 10000 else { throw TermRequest.Invalid("invalid key delays") }
                    // Validate the entire sequence before sending its text.
                    var validation = params
                    validation["verb"] = "validate"
                    _ = try call("terminal.control", validation)
                    let keys = params["keys"] as? [String] ?? []
                    params["keys"] = [String]()
                    _ = try call("terminal.control", params)
                    params.removeValue(forKey: "text")
                    for (index, key) in keys.enumerated() {
                        if delays[index] > 0 { Thread.sleep(forTimeInterval: Double(delays[index]) / 1000) }
                        params["keys"] = [key]
                        _ = try call("terminal.control", params)
                    }
                    params["verb"] = "screen"
                }
                reply(TermResponse(try call("terminal.control", params)))
            } catch is PaneTimeout { reply(.error(408, "screen wait timed out")) }
            catch { reply(.error(409, error.localizedDescription)) }
            #else
            reply(.error(501, "Herdr is not embedded in this build"))
            #endif
        }
    }

    private struct PaneTimeout: Error {}
}
