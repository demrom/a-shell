import SwiftTerm

// Exercise the public terminal API used by the bridge, with the real encoder.
let host = HeadlessTerminal { _ in }
let terminal = host.terminal!
precondition(terminal.encodeKeyboardKey("ctrl-b") == [2], "Herdr prefix must encode as STX")
let controls: [(String, UInt8)] = [
    ("a", 1), ("b", 2), ("c", 3), ("d", 4), ("e", 5), ("f", 6), ("g", 7),
    ("h", 8), ("i", 9), ("j", 10), ("k", 11), ("l", 12), ("m", 13), ("n", 14),
    ("o", 15), ("p", 16), ("q", 17), ("r", 18), ("s", 19), ("t", 20), ("u", 21),
    ("v", 22), ("w", 23), ("x", 24), ("y", 25), ("z", 26), ("@", 0), ("[", 27),
    ("\\", 28), ("]", 29), ("^", 30), ("_", 31)
]
for (key, byte) in controls {
    precondition(terminal.encodeKeyboardKey("ctrl-" + key) == [byte], "Control chord failed: \(key)")
}
let sequences: [(String, String)] = [
    ("esc", "\u{1b}"), ("enter", "\r"), ("tab", "\t"), ("shift-tab", "\u{1b}[Z"),
    ("backspace", "\u{7f}"), ("delete", "\u{1b}[3~"), ("insert", "\u{1b}[2~"),
    ("up", "\u{1b}[A"), ("down", "\u{1b}[B"), ("right", "\u{1b}[C"), ("left", "\u{1b}[D"),
    ("home", "\u{1b}[H"), ("end", "\u{1b}[F"), ("pageup", "\u{1b}[5~"), ("pagedown", "\u{1b}[6~"),
    ("f1", "\u{1b}OP"), ("f2", "\u{1b}OQ"), ("f3", "\u{1b}OR"), ("f4", "\u{1b}OS"),
    ("f5", "\u{1b}[15~"), ("f6", "\u{1b}[17~"), ("f7", "\u{1b}[18~"), ("f8", "\u{1b}[19~"),
    ("f9", "\u{1b}[20~"), ("f10", "\u{1b}[21~"), ("f11", "\u{1b}[23~"), ("f12", "\u{1b}[24~"),
    ("alt-b", "\u{1b}b"), ("meta-f", "\u{1b}f"), ("shift-x", "X"),
    ("ctrl-up", "\u{1b}[1;5A"), ("alt-left", "\u{1b}[1;3D"),
    ("shift-home", "\u{1b}[1;2H"), ("ctrl-alt-shift-end", "\u{1b}[1;8F")
]
for (key, expected) in sequences {
    precondition(terminal.encodeKeyboardKey(key) == Array(expected.utf8), "Named key failed: \(key)")
}
precondition(terminal.encodeKeyboardKey("backspace", backspaceSendsControlH: true) == [8])
precondition(terminal.encodeKeyboardKey("keypad1") == [49])
terminal.feed(text: "\u{1b}[?1h\u{1b}=")
precondition(terminal.encodeKeyboardKey("up") == Array("\u{1b}OA".utf8), "DECCKM must use SS3")
precondition(terminal.encodeKeyboardKey("keypad1") == Array("\u{1b}Oq".utf8), "Application keypad must use SS3")
precondition(terminal.encodeKeyboardKey("ctrl-up") == Array("\u{1b}[1;5A".utf8))
terminal.feed(text: "\u{1b}[?1l\u{1b}>")
precondition(terminal.encodeKeyboardKey("up") == Array("\u{1b}[A".utf8))
precondition(terminal.encodeKeyboardKey("keypad1") == [49])
precondition(terminal.encodeKeyboardKey("ctrl-shift-x") == Array("\u{1b}[120;6u".utf8), "Extended chords use the encoder's CSI-u fallback")
terminal.feed(text: "\u{1b}[>1u")
precondition(terminal.encodeKeyboardKey("ctrl-shift-x") == Array("\u{1b}[120;6u".utf8), "Kitty must preserve expressible modifiers")
for invalid in ["bogus", "ctrl-", "ctrl-ctrl-b", "alt-meta-b", "super-b", "f13"] {
    precondition(terminal.encodeKeyboardKey(invalid) == nil, "Unknown chord accepted: \(invalid)")
}
print("keyboard control boundary PASS")
