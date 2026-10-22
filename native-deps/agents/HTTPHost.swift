import Foundation
import Dispatch

// A real Mac process supplies the OS command boundary for transport tests.
@main
struct HTTPHost {
    static func main() throws {
        let root = CommandLine.arguments[1]
        let server = try AgentServer(root: root, tokensFile: URL(fileURLWithPath: root + "/.agentd-tokens"), execute: { command, cwd in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (Int(process.terminationStatus), bytes)
            } catch { return (-1, Data(error.localizedDescription.utf8)) }
        }, terminal: { _, _, reply in reply(.init(503, "no foreground terminal\n")) })
        try server.start(port: 0) { result in
            switch result {
            case .success(let port): print("https://localhost:\(port)"); fflush(stdout)
            case .failure(let error): fputs("\(error)\n", stderr); exit(1)
            }
        }
        withExtendedLifetime(server) { dispatchMain() }
    }
}
