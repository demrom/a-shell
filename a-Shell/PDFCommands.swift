import Foundation
import ImageIO
import PDFKit
import ios_system

private struct PDFCommandError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

private enum PDFCommand: String {
    case pdftotext, pdftoppm, pdfinfo

    var usage: String {
        switch self {
        case .pdftotext: return "pdftotext [-f N] [-l N] [-layout] input.pdf [output.txt|-]"
        case .pdftoppm: return "pdftoppm [-f N] [-l N] [-r DPI] -png input.pdf prefix"
        case .pdfinfo: return "pdfinfo input.pdf"
        }
    }

    func run(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
        guard let arguments = convertCArguments(argc: argc, argv: argv) else { return 1 }
        return autoreleasepool {
            do {
                var first = 1
                var last: Int?
                var resolution = 150.0
                var layout = false
                var png = false
                var paths: [String] = []
                var parseOptions = true
                var args = arguments.dropFirst().makeIterator()
                while let arg = args.next() {
                    if parseOptions && arg == "--" {
                        parseOptions = false
                    } else if parseOptions && arg.hasPrefix("-") && arg != "-" {
                        switch arg {
                        case "-f", "-l":
                            guard self != .pdfinfo else { throw PDFCommandError("unsupported option: \(arg)") }
                            guard let value = args.next(), let number = Int(value), number > 0 else {
                                throw PDFCommandError("\(arg) requires a positive page number")
                            }
                            if arg == "-f" { first = number } else { last = number }
                        case "-r" where self == .pdftoppm:
                            guard let value = args.next(), let number = Double(value), number.isFinite, number > 0 else {
                                throw PDFCommandError("-r requires a positive resolution in DPI")
                            }
                            resolution = number
                        case "-layout" where self == .pdftotext: layout = true
                        case "-png" where self == .pdftoppm: png = true
                        default: throw PDFCommandError("unsupported option: \(arg)")
                        }
                    } else {
                        paths.append(arg)
                    }
                }
                switch self {
                case .pdftotext where !(1...2).contains(paths.count),
                     .pdftoppm where paths.count != 2 || !png,
                     .pdfinfo where paths.count != 1:
                    throw PDFCommandError("usage: \(usage)")
                default: break
                }

                let input = paths[0]
                guard input != "-" else { throw PDFCommandError("standard input is not supported; pass a PDF file") }
                let inputURL = URL(fileURLWithPath: input)
                guard let document = PDFDocument(url: inputURL) else {
                    throw PDFCommandError("cannot open PDF: \(input)")
                }
                guard !document.isLocked else { throw PDFCommandError("PDF is locked: \(input)") }
                if self == .pdfinfo {
                    try Self.write("Pages:          \(document.pageCount)\n", to: thread_stdout)
                    return 0
                }
                let end = min(last ?? document.pageCount, document.pageCount)
                guard first <= end else { throw PDFCommandError("invalid page range \(first)...\(end)") }
                let pages = first...end
                if self == .pdftotext {
                    let defaultOutput = inputURL.deletingPathExtension().appendingPathExtension("txt").path
                    try Self.extract(document, pages: pages, layout: layout, output: paths.dropFirst().first ?? defaultOutput)
                } else {
                    let digits = String(document.pageCount).count
                    for number in pages {
                        let suffix = String(number)
                        let padding = String(repeating: "0", count: digits - suffix.count)
                        try autoreleasepool {
                            try Self.render(Self.page(document, number), resolution: resolution,
                                            output: "\(paths[1])-\(padding)\(suffix).png")
                        }
                    }
                }
                return 0
            } catch {
                fputs("\(rawValue): \(error.localizedDescription)\n", thread_stderr)
                return 1
            }
        }
    }

    private static func page(_ document: PDFDocument, _ number: Int) throws -> PDFPage {
        guard let page = document.page(at: number - 1) else { throw PDFCommandError("cannot read page \(number)") }
        return page
    }

    private static func write(_ text: String, to stream: UnsafeMutablePointer<FILE>) throws {
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, stream) }
        guard written == bytes.count, fflush(stream) == 0 else { throw PDFCommandError("cannot write output") }
    }

    private static func extract(_ document: PDFDocument, pages: ClosedRange<Int>, layout: Bool, output: String) throws {
        var file: UnsafeMutablePointer<FILE>?
        if output != "-" {
            // Open only after validating the document and range. Avoid truncating the PDF
            // when the destination is the input itself (including aliases or hard links).
            var source = stat()
            var destination = stat()
            if let path = document.documentURL?.path, stat(path, &source) == 0,
               stat(output, &destination) == 0, source.st_dev == destination.st_dev, source.st_ino == destination.st_ino {
                throw PDFCommandError("input and output are the same file")
            }
            guard let opened = fopen(output, "wb") else { throw PDFCommandError("cannot open output: \(output)") }
            file = opened
        }
        defer { if let file = file { fclose(file) } }
        for number in pages {
            try autoreleasepool {
                let page = try Self.page(document, number)
                let text = layout ? layoutText(page) : (page.string ?? "")
                let body = text.trimmingCharacters(in: .newlines)
                try write(body.isEmpty ? "\u{0c}" : body + (layout ? "\n\u{0c}" : "\n\n\u{0c}"), to: file ?? thread_stdout)
            }
        }
    }

    private static func layoutText(_ page: PDFPage) -> String {
        let text = (page.string ?? "") as NSString
        let range = NSRange(location: 0, length: text.length)
        guard page.rotation == 0, range.length > 0, range.length == page.numberOfCharacters,
              let selection = page.selection(for: range),
              let words = try? NSRegularExpression(pattern: "\\S+") else { return text as String }

        // PDFKit can represent a wide gap as one space even within a single line.
        // Place words by their glyph coordinates on an approximate fixed-width grid.
        var runs: [(text: String, x: CGFloat, line: CGRect, cellWidth: CGFloat)] = []
        for line in selection.selectionsByLine() {
            let bounds = line.bounds(for: page)
            guard !bounds.isEmpty, bounds.midY.isFinite, bounds.height.isFinite else { continue }
            for index in 0..<line.numberOfTextRanges(on: page) {
                let span = line.range(at: index, on: page)
                guard span.location <= range.length, span.length <= range.length - span.location else { return text as String }
                var usable = true
                words.enumerateMatches(in: text as String, range: span) { match, _, _ in
                    guard let word = match?.range else { return }
                    let left = page.characterBounds(at: word.location).minX
                    let right = page.characterBounds(at: NSMaxRange(word) - 1).maxX
                    let width = (right - left) / CGFloat(word.length)
                    guard left.isFinite, width.isFinite, width > 0 else { usable = false; return }
                    runs.append((text.substring(with: word), left, bounds, width))
                }
                guard usable else { return text as String }
            }
        }
        runs.sort { $0.line.midY > $1.line.midY }
        guard let left = runs.map(\.x).min() else { return text as String }
        let widths = runs.map(\.cellWidth).sorted()
        let cellWidth = max(1, widths[widths.count / 2])
        var rows: [String] = []
        var start = 0
        while start < runs.count {
            let baseline = runs[start].line
            var end = start + 1
            while end < runs.count && baseline.midY - runs[end].line.midY < baseline.height / 2 {
                end += 1
            }
            var row = ""
            for run in runs[start..<end].sorted(by: { $0.x < $1.x }) {
                let column = Int(min(4096, ((run.x - left) / cellWidth).rounded()))
                row += String(repeating: " ", count: max(row.isEmpty ? 0 : 1, column - row.count)) + run.text
            }
            rows.append(row)
            start = end
        }
        return rows.joined(separator: "\n")
    }

    private static func render(_ page: PDFPage, resolution: Double, output: String) throws {
        guard let pdf = page.pageRef else { throw PDFCommandError("cannot read page graphics") }
        let bounds = pdf.getBoxRect(.mediaBox)
        let sideways = pdf.rotationAngle % 180 != 0
        let scale = resolution / 72
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let width = ceil(sideways ? size.height : size.width)
        let height = ceil(sideways ? size.width : size.height)
        // Reject outsize bitmaps before allocating them in the terminal's process.
        guard width >= 1, height >= 1, width * height <= 16_000_000,
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PDFCommandError("page is too large or invalid at \(resolution) DPI")
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let drawing = CGRect(x: 0, y: 0, width: sideways ? size.height : size.width,
                             height: sideways ? size.width : size.height)
        context.concatenate(pdf.getDrawingTransform(.mediaBox, rect: drawing, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(pdf)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                                "public.png" as CFString, 1, nil) else {
            throw PDFCommandError("cannot create PNG: \(output)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PDFCommandError("cannot write PNG: \(output)") }
    }
}

@_cdecl("pdftotext")
public func pdftotext(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    PDFCommand.pdftotext.run(argc: argc, argv: argv)
}

@_cdecl("pdftoppm")
public func pdftoppm(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    PDFCommand.pdftoppm.run(argc: argc, argv: argv)
}

@_cdecl("pdfinfo")
public func pdfinfo(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    PDFCommand.pdfinfo.run(argc: argc, argv: argv)
}
