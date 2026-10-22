import Foundation

// The request parser is the public contract shared by CLI, HTTP and XPC.
@main
struct TermContract {
    static func main() throws {
        let bytes = try TermRequest.parse(["keys", #"\e[6~\x00\xff"#, "--window", "target"])
        precondition(bytes.bytes == Data([27, 91, 54, 126, 0, 255]))
        precondition(bytes.window == "target")
        let text = try TermRequest.parse(["type", "--key", "enter", "--", "--literal Привет"])
        precondition(text.text == "--literal Привет" && text.keys == ["enter"])
        let http = try TermRequest.http("/type?window=target&pane=w1%3Ap2", body: Data(#"{"text":"hello","keys":["enter"],"delay_ms":[12]}"#.utf8))
        precondition(http.window == "target" && http.pane == "w1:p2" && http.text == "hello" && http.keys == ["enter"] && http.delays == [12])
        let screen = try TermRequest.http("/screen?window=target", body: Data())
        precondition(screen.window == "target" && screen.json)
        let colors = try TermRequest.parse(["screen", "--colors"])
        precondition(colors.colors && colors.json)
        let httpColors = try TermRequest.http("/screen?colors=true", body: Data())
        precondition(httpColors.colors && httpColors.json)
        let bodyColors = try TermRequest.http("/screen", body: Data(#"{"colors":true}"#.utf8))
        precondition(bodyColors.colors)
        let shot = try TermRequest.http("/shot?window=target", body: Data())
        precondition(shot.verb == "shot")
        print("PASS: literal Unicode, raw bytes, explicit targets, HTTP parity and screenshot request")
    }
}
