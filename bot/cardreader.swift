import Foundation

// bot/cards.py does the card reading. It runs once in the background and answers one JSON
// line for each capture path written to it.
final class CardReader {
    struct Answer: Decodable {
        var board: [String]
        var hole: [String]
        var problems: [String]
    }

    private let python: URL
    private let script: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    init(projectDirectory: URL) {
        python = projectDirectory.appendingPathComponent(".venv/bin/python3")
        script = projectDirectory.appendingPathComponent("bot/cards.py")
        // A reader that died must surface as a failed write, not end this program.
        signal(SIGPIPE, SIG_IGN)
    }

    var setupHint: String? {
        if !FileManager.default.fileExists(atPath: script.path) { return "missing \(script.path)" }
        if !FileManager.default.fileExists(atPath: python.path) {
            return "missing .venv. Run: python3 -m venv .venv && .venv/bin/pip install numpy opencv-python-headless"
        }
        return nil
    }

    func read(_ path: String) -> Answer {
        if process?.isRunning != true { start() }
        guard let input, let output else { return failed("the card reader did not start") }
        do {
            try input.write(contentsOf: Data((path + "\n").utf8))
        } catch {
            stop()
            return failed("the card reader stopped")
        }
        guard let line = readLine(output) else {
            stop()
            return failed("the card reader stopped")
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: line) else {
            return failed("the card reader gave an unreadable answer")
        }
        return answer
    }

    private func start() {
        stop()
        guard setupHint == nil else { return }
        let toReader = Pipe()
        let fromReader = Pipe()
        let p = Process()
        p.executableURL = python
        p.arguments = [script.path, "--serve"]
        p.standardInput = toReader
        p.standardOutput = fromReader
        p.standardError = FileHandle.standardError
        do { try p.run() } catch { return }
        process = p
        input = toReader.fileHandleForWriting
        output = fromReader.fileHandleForReading
    }

    private func stop() {
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        buffer = Data()
    }

    private func readLine(_ handle: FileHandle) -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                return Data(line)
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    private func failed(_ why: String) -> Answer {
        Answer(board: [], hole: [], problems: [why])
    }
}

func card(named name: String) -> Card? {
    guard let suitLetter = name.last, let rank = Card.rankValue(String(name.dropLast())) else { return nil }
    let suits: [Character: Suit] = ["c": .clubs, "d": .diamonds, "h": .hearts, "s": .spades]
    guard let suit = suits[suitLetter] else { return nil }
    return Card(rank: rank, suit: suit)
}
