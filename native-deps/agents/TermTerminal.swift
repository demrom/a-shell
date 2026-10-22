import UIKit
import SwiftTerm
import ios_system

// Main-thread ownership matches UIKit keyboard input and terminal output.
final class TermTerminal {
    static let shared = TermTerminal()
    private var typing: Set<String> = []
    private var screens: [String: Data] = [:]
    private var sequences: [String: UInt64] = [:]

    private func scenes() -> [SceneDelegate] {
        UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.filter { $0.terminalView != nil }
    }

    private func connected(_ scene: SceneDelegate, _ view: TerminalView) -> Bool {
        scenes().contains { $0 === scene } && scene.terminalView === view
    }

    private func visible(_ scene: SceneDelegate) -> Bool {
        guard let window = scene.terminalView?.window, !window.isHidden, window.alpha > 0 else { return false }
        return window.windowScene?.activationState == .foregroundActive || window.windowScene?.activationState == .foregroundInactive
    }

    func scene(window: String? = nil) -> SceneDelegate? {
        let terminals = scenes()
        let candidates: [SceneDelegate]
        if let window {
            candidates = terminals.filter { $0.persistentIdentifier == window }
        } else if terminals.count == 1 {
            candidates = terminals
        } else {
            candidates = terminals.filter { visible($0) }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    func perform(_ request: TermRequest, reply: @escaping (TermResponse) -> Void) {
        precondition(Thread.isMainThread)
        if request.verb == "windows" {
            reply(TermResponse(["windows": scenes().map { scene -> [String: Any] in
                ["window": scene.persistentIdentifier ?? "", "foreground": visible(scene), "active": scene.terminalView?.window?.windowScene?.activationState == .foregroundActive, "command": scene.currentCommand]
            }]))
            return
        }
        let terminals = scenes()
        guard let scene = scene(window: request.window), let view = scene.terminalView else {
            if request.window == nil, !terminals.isEmpty {
                reply(TermResponse(409, ["error": "ambiguous terminal; select --window ID", "windows": terminals.map { $0.persistentIdentifier ?? "" }]))
            } else {
                reply(.error(503, "no connected terminal for the selected window"))
            }
            return
        }
        if request.verb == "shot", !visible(scene) {
            reply(.error(503, "background terminal screenshot unavailable: UIKit view rendering requires a foreground scene"))
            return
        }
        if request.pane != nil || request.verb == "panes" {
            guard scene.currentCommand.hasPrefix("herdr") else { reply(.error(409, "selected window is not running Herdr")); return }
            let identity = "\(scene.persistentIdentifier ?? "")/\(request.pane ?? "")"
            let sendsInput = ["type", "keys", "paste"].contains(request.verb)
            if sendsInput {
                guard !typing.contains(identity) else { reply(.error(409, "a key sequence is already running for this pane")); return }
                typing.insert(identity)
            }
            TermPane.perform(request) { response in
                DispatchQueue.main.async {
                    if sendsInput { self.typing.remove(identity) }
                    guard self.connected(scene, view) else { reply(.error(503, "target terminal disconnected")); return }
                    if request.verb == "shot", response.status == 200 {
                        guard self.visible(scene) else { reply(.error(503, "background terminal screenshot unavailable: UIKit view rendering requires a foreground scene")); return }
                        reply(self.paneImage(response, view))
                    } else if request.verb == "state", response.status == 200, var value = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
                        value["foreground"] = self.visible(scene)
                        value["active"] = view.window?.windowScene?.activationState == .foregroundActive
                        value["window"] = scene.persistentIdentifier ?? ""
                        reply(TermResponse(value))
                    } else { reply(response) }
                }
            }
            return
        }
        let terminal = view.getTerminal()
        switch request.verb {
        case "screen": reply(snapshot(scene, view, colors: request.colors))
        case "scrollback":
            let last = terminal.buffer.yDisp + terminal.rows
            let first = max(0, last - (request.lines ?? last))
            let rows = (first..<last).map { terminal.getScrollInvariantLine(row: terminal.buffer.totalLinesTrimmed + $0)?.translateToString(trimRight: true).replacingOccurrences(of: "\u{0}", with: " ") ?? "" }
            reply(TermResponse(["rows": rows, "window": scene.persistentIdentifier ?? ""]))
        case "size": reply(TermResponse(["columns": terminal.cols, "height": terminal.rows]))
        case "cursor":
            let cursor = terminal.getCursorLocation()
            reply(TermResponse(["row": cursor.y, "column": cursor.x]))
        case "state":
            reply(TermResponse(["foreground": visible(scene), "active": view.window?.windowScene?.activationState == .foregroundActive, "command": scene.currentCommand, "pid": scene.pid, "pid_kind": "ios_system session", "window": scene.persistentIdentifier ?? ""]))
        case "resize":
            guard let cols = request.columns, let rows = request.rows else { reply(.error(400, "resize requires geometry")); return }
            terminal.resize(cols: cols, rows: rows)
            scene.sizeChanged(source: view, newCols: cols, newRows: rows)
            reply(TermResponse(["columns": terminal.cols, "height": terminal.rows]))
        case "clear":
            view.feed(text: "\u{1b}[H\u{1b}[2J")
            reply(snapshot(scene, view))
        case "shot":
            view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in view.layer.render(in: context.cgContext) }
            guard let bytes = image.pngData() else { reply(.error(500, "PNG encoding failed")); return }
            reply(TermResponse(status: 200, data: bytes, contentType: "image/png"))
        case "wait": wait(request, scene, view, reply: reply)
        case "type", "keys", "paste": type(request, scene, view, reply: reply)
        default: reply(.error(400, "unknown terminal operation"))
        }
    }

    private func paneImage(_ response: TermResponse, _ view: TerminalView) -> TermResponse {
        guard let value = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any], let cells = value["cells"] as? [[[String: Any]]], let columns = value["columns"] as? Int, let rows = value["height"] as? Int else { return .error(500, "invalid rendered pane") }
        let font = view.font
        let cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        let cellHeight = font.lineHeight
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(columns) * cellWidth, height: CGFloat(rows) * cellHeight)
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            view.nativeBackgroundColor.setFill()
            UIRectFill(bounds)
            for (row, line) in cells.enumerated() {
                for (column, cell) in line.enumerated() {
                    let rect = CGRect(x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight, width: cellWidth, height: cellHeight)
                    Self.color(cell["background"] as? String, fallback: view.nativeBackgroundColor).setFill()
                    UIRectFill(rect)
                }
            }
            // Paint all backgrounds before glyphs so a wide glyph survives its
            // following display cell; UIKit shapes combining characters together.
            for (row, line) in cells.enumerated() {
                for (column, cell) in line.enumerated() {
                    var traits: UIFontDescriptor.SymbolicTraits = []
                    if cell["bold"] as? Bool == true { traits.insert(.traitBold) }
                    if cell["italic"] as? Bool == true { traits.insert(.traitItalic) }
                    let styled = font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
                    var foreground = Self.color(cell["foreground"] as? String, fallback: view.nativeForegroundColor)
                    if cell["dim"] as? Bool == true { foreground = foreground.withAlphaComponent(0.5) }
                    var attributes: [NSAttributedString.Key: Any] = [.font: styled, .foregroundColor: foreground]
                    if cell["underline"] as? Bool == true { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if cell["strike"] as? Bool == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    (cell["text"] as? String ?? " ").draw(at: CGPoint(x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight), withAttributes: attributes)
                }
            }
            if let cursor = value["cursor"] as? [String: Any], cursor["visible"] as? Bool == true, let column = cursor["column"] as? Int, let row = cursor["row"] as? Int {
                view.caretColor.setStroke()
                UIRectFrame(CGRect(x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight, width: cellWidth, height: cellHeight))
            }
        }
        guard let png = image.pngData() else { return .error(500, "PNG encoding failed") }
        return TermResponse(status: 200, data: png, contentType: "image/png")
    }

    private static func color(_ name: String?, fallback: UIColor) -> UIColor {
        guard let name else { return fallback }
        if name.hasPrefix("#"), let value = UInt32(name.dropFirst(), radix: 16) {
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        let colors: [String: UIColor] = ["Black": .black, "Red": .red, "Green": .green, "Yellow": .yellow, "Blue": .blue, "Magenta": .magenta, "Cyan": .cyan, "Gray": .lightGray, "DarkGray": .darkGray, "White": .white]
        return colors[name] ?? fallback
    }

    private func snapshot(_ scene: SceneDelegate, _ view: TerminalView, colors: Bool = false) -> TermResponse {
        let terminal = view.getTerminal()
        let rows = (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true).replacingOccurrences(of: "\u{0}", with: " ") ?? "" }
        let cursor = terminal.getCursorLocation()
        let cells: [[Any]] = (0..<terminal.rows).map { row in
            (0..<terminal.cols).map { column -> Any in
                let text = terminal.getCharacter(col: column, row: row).map { $0 == "\0" ? " " : String($0) } ?? " "
                guard colors, let cell = terminal.getCharData(col: column, row: row) else { return text }
                let attribute = cell.attribute
                let style = attribute.style
                return ["text": text, "foreground": Self.cellColor(attribute.fg), "background": Self.cellColor(attribute.bg),
                    "bold": style.contains(.bold), "italic": style.contains(.italic), "dim": style.contains(.dim),
                    "underline": style.contains(.underline) || attribute.underlineStyle != .none, "strike": style.contains(.crossedOut),
                    "inverse": style.contains(.inverse), "invisible": style.contains(.invisible), "blink": style.contains(.blink)] as [String: Any]
            }
        }
        let window = scene.persistentIdentifier ?? ""
        var value: [String: Any] = ["rows": rows, "cells": cells, "columns": terminal.cols, "height": terminal.rows, "cursor": ["row": cursor.y, "column": cursor.x], "window": window, "pane": "main"]
        let content = TermResponse(value).data
        if screens[window] != content {
            screens[window] = content
            sequences[window, default: 0] += 1
        }
        value["seq"] = sequences[window, default: 0]
        return TermResponse(value)
    }

    private static func cellColor(_ color: Attribute.Color) -> String {
        switch color {
        case .ansi256(let code): return String(code)
        case .trueColor(let red, let green, let blue): return String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue))
        case .defaultColor, .defaultInvertedColor: return "Reset"
        }
    }

    private func type(_ request: TermRequest, _ scene: SceneDelegate, _ view: TerminalView, reply: @escaping (TermResponse) -> Void) {
        let identity = scene.persistentIdentifier ?? ""
        let keys = request.keys
        let delays = request.delays.isEmpty ? Array(repeating: 0, count: keys.count) : request.delays
        guard keys.count <= 256, delays.count == keys.count, delays.allSatisfy({ (0...2000).contains($0) }), delays.reduce(0, +) <= 10000 else {
            reply(.error(400, "delay_ms must match keys, each 0...2000 ms, total <=10000 ms, at most 256 keys")); return
        }
        let aliases = ["pgdn": "pagedown", "pgup": "pageup"]
        let normalized = keys.map { aliases[$0.lowercased()] ?? $0 }
        for key in normalized where view.getTerminal().encodeKeyboardKey(key, backspaceSendsControlH: view.backspaceSendsControlH) == nil {
            reply(.error(400, "unknown or unrepresentable key: \(key)")); return
        }
        guard !typing.contains(identity) else { reply(.error(409, "a key sequence is already running for this window")); return }
        typing.insert(identity)
        if request.verb == "keys" {
            let bytes = Array(request.bytes ?? Data((request.text ?? "").utf8))
            view.send(data: bytes[...])
        } else if request.verb == "paste" {
            let terminal = view.getTerminal()
            if terminal.bracketedPasteMode { view.send(data: Array("\u{1b}[200~".utf8)[...]) }
            view.send(data: Array((request.text ?? "").utf8)[...])
            if terminal.bracketedPasteMode { view.send(data: Array("\u{1b}[201~".utf8)[...]) }
        } else if let text = request.text {
            // The shell line editor recognizes Return only as a separate input.
            for character in text { view.insertText(String(character)) }
        }
        func step(_ index: Int) {
            guard self.connected(scene, view) else {
                self.typing.remove(identity)
                reply(.error(409, "target terminal disconnected")); return
            }
            if index == normalized.count {
                self.typing.remove(identity)
                reply(self.snapshot(scene, view)); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delays[index])) {
                guard self.connected(scene, view), let bytes = view.getTerminal().encodeKeyboardKey(normalized[index], backspaceSendsControlH: view.backspaceSendsControlH) else {
                    self.typing.remove(identity)
                    reply(.error(409, "target terminal or key mode changed")); return
                }
                if normalized[index].lowercased() == "enter", view.getTerminal().keyboardEnhancementFlags.isEmpty { view.insertText("\n") }
                else { view.send(data: bytes[...]) }
                step(index + 1)
            }
        }
        step(0)
    }

    private func wait(_ request: TermRequest, _ scene: SceneDelegate, _ view: TerminalView, reply: @escaping (TermResponse) -> Void) {
        guard let pattern = request.text, let regex = try? NSRegularExpression(pattern: pattern) else { reply(.error(400, "invalid --text regular expression")); return }
        var observer: NSObjectProtocol?
        var disconnectObserver: NSObjectProtocol?
        var finished = false
        var timeout: DispatchWorkItem?
        func complete(_ response: TermResponse) {
            guard !finished else { return }
            finished = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
            timeout?.cancel()
            reply(response)
        }
        func check() {
            guard self.connected(scene, view) else { complete(.error(503, "target terminal disconnected")); return }
            let snapshot = self.snapshot(scene, view)
            let object = try? JSONSerialization.jsonObject(with: snapshot.data) as? [String: Any]
            let text = (object?["rows"] as? [String] ?? []).joined(separator: "\n")
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { complete(snapshot) }
        }
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("AShellTerminalOutput"), object: view.getTerminal(), queue: .main) { _ in check() }
        disconnectObserver = NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification, object: view.window?.windowScene, queue: .main) { _ in check() }
        timeout = DispatchWorkItem { complete(.error(408, "screen wait timed out")) }
        DispatchQueue.main.asyncAfter(deadline: .now() + request.timeout, execute: timeout!)
        check()
    }
}

final class TermControlService: NSObject, TermControlWire {
    static let shared = TermControlService()
    func terminal(_ data: Data, reply: @escaping (Int, Data, String) -> Void) {
        do {
            let request = try JSONDecoder().decode(TermRequest.self, from: data)
            DispatchQueue.main.async {
                TermTerminal.shared.perform(request) { result in reply(result.status, result.data, result.contentType) }
            }
        } catch { reply(400, Data(error.localizedDescription.utf8), "text/plain; charset=utf-8") }
    }
}

@_cdecl("ashell_term")
public func ashellTerm(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    guard argc > 0, let argv else { return 2 }
    guard !Thread.isMainThread else { return 1 }
    let arguments = (1..<Int(argc)).map { String(cString: argv[$0]!) }
    // ios_system streams belong to this command thread, never the UI callback.
    let output = thread_stdout
    let error = thread_stderr
    return TermCommand.run(arguments, perform: { request, reply in
        DispatchQueue.main.async { TermTerminal.shared.perform(request, reply: reply) }
    }, write: { bytes, failed in
        guard let stream = failed ? error : output else { return }
        bytes.withUnsafeBytes { buffer in
            if let address = buffer.baseAddress { _ = fwrite(address, 1, buffer.count, stream) }
        }
        fflush(stream)
    })
}
