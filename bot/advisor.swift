import Foundation

// What fullhouse-bot would do. `probs` is fold, check/call, half-pot, pot, all-in.
struct ModelAdvice {
    var probs: [Double]
    var best: String
    var raiseTo: Double?
    var source: String
}

// The model needs a dealer, a blind, and a stack for everyone still in the hand.
func modelInputsReady(_ table: TableRead) -> Bool {
    guard let dealer = table.dealerSeat, table.seats.indices.contains(dealer), table.seats[dealer].dealt else {
        return false
    }
    guard let blind = table.bigBlind, blind > 0 else { return false }
    guard table.seats.filter(\.dealt).count >= 2 else { return false }
    guard table.seats[0].dealt, !table.seats[0].folded else { return false }
    for seat in table.seats where seat.dealt {
        if seat.stack == nil && !seat.allIn { return false }
    }
    if table.canCall && (table.toCall <= 0 || table.toCall >= 1e15) { return false }
    return true
}

func cardCode(_ card: Card) -> String {
    let suits = ["c", "d", "h", "s"]
    return Card.rankLetter(card.rank) + suits[card.suit.rawValue]
}

// bot/advisor.py answers one JSON line per table. Same shape as the card reader:
// one background process, one request at a time.
final class AdvisorClient {
    private struct Answer: Decodable {
        var probs: [Double]?
        var best: String?
        var raiseTo: Double?
        var source: String?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case probs, best, source, error
            case raiseTo = "raise_to"
        }
    }

    private let python: URL
    private let script: URL
    private let model: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var reported = false

    init(projectDirectory: URL) {
        let preferred = projectDirectory.appendingPathComponent(".venv-advisor/bin/python3")
        let fallback = projectDirectory.appendingPathComponent(".venv/bin/python3")
        python = FileManager.default.fileExists(atPath: preferred.path) ? preferred : fallback
        script = projectDirectory.appendingPathComponent("bot/advisor.py")
        model = projectDirectory.appendingPathComponent("third_party/fullhouse-bot/data/deep_cfr_model.npz")
        signal(SIGPIPE, SIG_IGN)
    }

    var setupHint: String? {
        if !FileManager.default.fileExists(atPath: script.path) { return "missing \(script.path)" }
        if !FileManager.default.fileExists(atPath: model.path) {
            return "missing the fullhouse-bot model at \(model.path)"
        }
        if !FileManager.default.fileExists(atPath: python.path) {
            return "missing a Python with eval7. Use: /opt/homebrew/bin/python3.12 -m venv .venv-advisor && .venv-advisor/bin/pip install numpy 'eval7==0.1.11'"
        }
        return nil
    }

    func advise(_ table: TableRead) -> ModelAdvice? {
        if process?.isRunning != true { start() }
        guard let input, let output else { return fail("the advisor did not start") }
        guard let body = try? JSONSerialization.data(withJSONObject: payload(table)) else {
            return fail("the table could not be sent")
        }
        var line = body
        line.append(0x0A)
        do {
            try input.write(contentsOf: line)
        } catch {
            stop()
            return fail("the advisor stopped")
        }
        guard let raw = readLine(output),
              let answer = try? JSONDecoder().decode(Answer.self, from: raw) else {
            stop()
            return fail("the advisor stopped")
        }
        if let error = answer.error, !error.isEmpty { return fail(error) }
        guard let probs = answer.probs, probs.count == 5, let best = answer.best, let source = answer.source else {
            return fail("the advisor gave an unreadable answer")
        }
        reported = false
        return ModelAdvice(probs: probs, best: best, raiseTo: answer.raiseTo, source: source)
    }

    private func payload(_ table: TableRead) -> [String: Any] {
        var seats: [[String: Any]] = []
        for (index, seat) in table.seats.enumerated() {
            var item: [String: Any] = [
                "dealt": seat.dealt,
                "bet": seat.bet,
                "invested": index < table.invested.count ? table.invested[index] : 0,
                "folded": seat.folded,
                "all_in": seat.allIn,
            ]
            if let stack = seat.stack { item["stack"] = stack }
            seats.append(item)
        }
        return [
            "big_blind": table.bigBlind ?? 0,
            "hero": 0,
            "dealer": table.dealerSeat ?? 0,
            "hole": table.hole.map(cardCode),
            "board": table.board.map(cardCode),
            "pot": table.pot ?? 0,
            "to_call": table.canCheck ? 0 : table.toCall,
            "can_check": table.canCheck,
            "seats": seats,
            "raises": table.raises.map { ["seat": $0.seat, "total": $0.total] as [String: Any] },
        ]
    }

    private func start() {
        stop()
        guard setupHint == nil else { return }
        let toAdvisor = Pipe()
        let fromAdvisor = Pipe()
        let started = Process()
        started.executableURL = python
        started.arguments = [script.path, "--serve"]
        started.standardInput = toAdvisor
        started.standardOutput = fromAdvisor
        started.standardError = FileHandle.standardError
        do { try started.run() } catch { return }
        process = started
        input = toAdvisor.fileHandleForWriting
        output = fromAdvisor.fileHandleForReading
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

    private func fail(_ why: String) -> ModelAdvice? {
        if !reported {
            fputs("Model: \(why)\n", stderr)
            reported = true
        }
        return nil
    }
}
