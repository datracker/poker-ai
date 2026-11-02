import Foundation
import CoreGraphics
import Vision
import ImageIO

struct Word {
    var text: String
    var rect: CGRect
    var confidence: Float
}

// Clockwise from you: you, bottom-left, left, top, right. That is the order
// the action takes.
struct SeatRead {
    var occupied = false
    var dealt = false
    var stack: Double?
    var allIn = false
    var bet: Double = 0
    var folded = false
    var action: String?
}

struct RaiseLevel: Equatable, CustomStringConvertible {
    var seat: Int
    var total: Double
    var description: String { "\(seat):\(Int(total))" }
}

let seatNames = ["you", "bottom-left", "left", "top", "right"]

struct TableRead {
    var hole: [Card] = []
    var board: [Card] = []
    var cardProblems: [String] = []
    var heroStack: Double?
    var pot: Double?
    var bigBlind: Double?
    var toCall: Double = 0
    var canFold = false
    var canCheck = false
    var canCall = false
    var canRaise = false
    var ourTurn = false
    // "CALL ANY" and "CHECK/FOLD" are the buttons shown while someone else acts.
    var preAction = false
    // The raise slider covers the hole cards, so a frame with it open cannot be re-read.
    var sliderOpen = false
    var seats: [SeatRead] = Array(repeating: SeatRead(), count: 5)
    var dealerSeat: Int?
    // Filled in by TableMemory: this street's raises, and the chips each seat has put in.
    var raises: [RaiseLevel] = []
    var invested: [Double] = []
    var buttons: [String: CGPoint] = [:]
    var handLabel: String?
    var detail = ""

    var summary: String {
        let cards = cardList(hole)
        let street = cardList(board)
        let handDealt = handLabel != nil || !hole.isEmpty || !board.isEmpty
        let turn = ourTurn ? "your turn" : (handDealt ? "in hand" : "between hands")
        let money = [
            heroStack.map { "stack \(formatMoney($0))" },
            pot.map { "pot \(formatMoney($0))" },
            bigBlind.map { "bb \(formatMoney($0))" },
            toCall > 0 ? "call \(formatMoney(toCall))" : nil
        ].compactMap { $0 }.joined(separator: ", ")
        let label = handLabel.map { " (\($0))" } ?? ""
        let unclear = cardProblems.isEmpty ? "" : " | cards unclear"
        let moneyText = money.isEmpty ? "" : " | \(money)"
        return "\(turn)\(label) | hole [\(cards)] board [\(street)]\(moneyText)\(unclear)"
    }
}

func cardList(_ cards: [Card]) -> String {
    guard !cards.isEmpty else { return "" }
    // A space after each emoji keeps the closing bracket from drawing on top of it.
    return " " + cards.map(\.description).joined(separator: "  ") + " "
}

func formatMoney(_ n: Double) -> String {
    if n >= 1_000_000 { return String(format: n >= 10_000_000 ? "%.1fM" : "%.2fM", n / 1_000_000) }
    if n >= 1_000 { return String(format: n >= 100_000 ? "%.0fK" : "%.1fK", n / 1_000) }
    return String(format: "%.0f", n)
}

func readTable(_ image: CGImage, path: String, cards reader: CardReader) -> TableRead {
    let pixels = pixelBuffer(image)
    let words = recognizeText(image)
    var table = TableRead()
    table.handLabel = handLabel(in: words)

    let amounts = words.compactMap { word -> (Double, CGRect)? in
        guard let amount = parseMoney(word.text) else { return nil }
        return (amount, word.rect)
    }
    fillButtons(&table, words: words, pixels: pixels, imageHeight: pixels.height)
    table.sliderOpen = sliderIsOpen(words, width: pixels.width, height: pixels.height)
    readSeats(into: &table, words: words, pixels: pixels)
    if table.seats[0].allIn {
        table.heroStack = 0
    } else if let stack = table.seats[0].stack {
        table.heroStack = stack
    } else {
        table.heroStack = heroStack(amounts, width: pixels.width, height: pixels.height)
    }
    // A 2:1 pair after the flop is a bet and the pot, not the two blinds.
    if table.board.isEmpty {
        table.bigBlind = inferBigBlind(amounts, hero: table.heroStack, height: pixels.height)
    }
    table.pot = potAmount(amounts, width: pixels.width, height: pixels.height)
    if table.canCall {
        let nearCall = table.buttons["CALL"].map {
            CGRect(x: $0.x - 40, y: $0.y - 24, width: 90, height: 70)
        }
        table.toCall = callAmount(words, callRect: nearCall) ?? .greatestFiniteMagnitude
    }

    let read = reader.read(path)
    table.board = read.board.compactMap(card(named:))
    table.hole = read.hole.compactMap(card(named:))
    table.cardProblems = read.problems
    return table
}

func chooseAction(_ table: TableRead) -> Decision {
    if !table.cardProblems.isEmpty {
        if table.canCheck {
            return Decision(play: .check, reason: "the cards are not clear, and checking is free")
        }
        return Decision(play: .fold, reason: "the cards are not clear, and there is a bet to call")
    }
    if table.hole.count < 2 {
        if table.canCheck {
            return Decision(play: .check, reason: "your turn, and checking is free")
        }
        return Decision(play: .fold, reason: "your turn, and there is a bet to call")
    }
    if table.board.isEmpty {
        return preflopDecision(
            hole: table.hole,
            toCall: table.toCall,
            bigBlind: table.bigBlind,
            stack: table.heroStack,
            canCheck: table.canCheck
        )
    }
    if table.board.count < 3 {
        if table.canCheck {
            return Decision(play: .check, reason: "the board was only partly readable, so this checks")
        }
        return Decision(play: .fold, reason: "the board was only partly readable, so this folds")
    }
    return postflopDecision(
        hole: table.hole,
        board: table.board,
        toCall: table.toCall,
        pot: table.pot ?? 0,
        canCheck: table.canCheck
    )
}

// MARK: - Pixels

struct Pixels {
    var bytes: [UInt8]
    var width: Int
    var height: Int

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
}

func pixelBuffer(_ image: CGImage) -> Pixels {
    let width = image.width
    let height = image.height
    let rowBytes = width * 4
    let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: rowBytes * height)
    defer { raw.deallocate() }
    guard let ctx = CGContext(
        data: raw,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: rowBytes,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return Pixels(bytes: [], width: width, height: height)
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var bytes = [UInt8](repeating: 0, count: rowBytes * height)
    bytes.withUnsafeMutableBytes { dest in
        dest.baseAddress!.copyMemory(from: raw, byteCount: rowBytes * height)
    }
    return Pixels(bytes: bytes, width: width, height: height)
}

// MARK: - Text

func recognizeText(_ image: CGImage, level: VNRequestTextRecognitionLevel = .accurate) -> [Word] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level
    request.usesLanguageCorrection = false
    request.customWords = ["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2",
                            "FOLD", "CHECK", "CALL", "RAISE", "BET"]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch { return [] }
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    return (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        let rect = CGRect(
            x: box.minX * width,
            y: (1 - box.maxY) * height,
            width: box.width * width,
            height: box.height * height
        )
        return Word(text: candidate.string, rect: rect, confidence: candidate.confidence)
    }
}

func parseMoney(_ raw: String) -> Double? {
    if raw.contains("/") { return nil }
    var text = raw.uppercased()
    // "15,6M" is 15.6 million. "5,742,059" keeps its thousands separators.
    if let suffix = text.last, "KMB".contains(suffix) {
        let body = text.dropLast()
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        if parts.count == 2, parts[1].count == 1, parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber) {
            text = parts.joined(separator: ".") + String(suffix)
        }
    }
    text = text.replacingOccurrences(of: ",", with: "")
    text = String(text.filter { $0.isNumber || $0 == "." || $0 == "K" || $0 == "M" || $0 == "B" })
    guard !text.isEmpty else { return nil }
    let multiplier: Double
    if text.hasSuffix("B") {
        multiplier = 1_000_000_000
        text.removeLast()
    } else if text.hasSuffix("M") {
        multiplier = 1_000_000
        text.removeLast()
    } else if text.hasSuffix("K") {
        multiplier = 1_000
        text.removeLast()
    } else {
        multiplier = 1
    }
    guard let value = Double(text), value > 0 else { return nil }
    if multiplier == 1 && value < 1_000 { return nil }
    return value * multiplier
}

func handLabel(in words: [Word]) -> String? {
    let joined = words.map(\.text).joined(separator: " ").uppercased()
    let labels = ["STRAIGHT FLUSH", "FOUR OF A KIND", "FULL HOUSE", "THREE OF A KIND",
                  "TWO PAIR", "ONE PAIR", "HIGH CARD", "ROYAL FLUSH", "STRAIGHT", "FLUSH"]
    return labels.first { joined.contains($0) }
}

func fillButtons(_ table: inout TableRead, words: [Word], pixels: Pixels, imageHeight: Int) {
    let buttonRow = CGFloat(imageHeight) * 0.82
    let rowText = words
        .filter { $0.rect.midY >= buttonRow }
        .map { $0.text.uppercased() }
        .joined(separator: " ")
    table.preAction = rowText.contains("CALL ANY") || rowText.contains("CHECK/FOLD") || rowText.contains("CHECK / FOLD")
    for word in words {
        let upperWord = word.text.uppercased()
        if bannedWords.contains(where: { upperWord.contains($0) }) { continue }
        let token = upperWord
            .replacingOccurrences(of: "×", with: "X")
            .replacingOccurrences(of: "^", with: "")
            .trimmingCharacters(in: .whitespaces)
        // "CHECK/FOLD" contains both words, and "CALL ANY" is not a call button.
        if token.contains("/") || token.contains("ANY") { continue }
        let name: String?
        if token.contains("FOLD") { name = "FOLD" }
        else if token.contains("CHECK") { name = "CHECK" }
        else if token == "CALL" || token.hasPrefix("CALL ") { name = "CALL" }
        else if token.contains("RAISE") { name = "RAISE" }
        else if token == "BET" || token.hasPrefix("BET ") { name = "BET" }
        else { name = nil }
        guard let name, word.rect.midY >= buttonRow else { continue }
        let live = buttonIsLive(word.rect, pixels)
        table.buttons[name] = CGPoint(x: word.rect.midX, y: word.rect.midY)
        if name == "FOLD" { table.canFold = live }
        if name == "CHECK" { table.canCheck = live }
        if name == "CALL" { table.canCall = live }
        if name == "RAISE" || name == "BET" { table.canRaise = live || table.canRaise }
    }
    table.ourTurn = !table.preAction && (table.canFold || table.canCheck || table.canCall)
}

// A live button is a solid red, blue or gold pill. The buttons shown before your turn
// are dark inside, with only the lettering coloured, so the strip above the word is empty.
func buttonIsLive(_ rect: CGRect, _ pixels: Pixels) -> Bool {
    let x0 = max(0, Int(rect.minX) - 6)
    let x1 = min(pixels.width - 1, Int(rect.maxX) + 6)
    let y0 = max(0, Int(rect.minY) - 10)
    let y1 = min(pixels.height - 1, Int(rect.minY) - 1)
    guard x1 > x0, y1 > y0 else { return false }
    var fill = 0
    var total = 0
    var y = y0
    while y <= y1 {
        var x = x0
        while x <= x1 {
            total += 1
            if isButtonFill(pixels.rgb(x, y)) { fill += 1 }
            x += 1
        }
        y += 1
    }
    return Double(fill) / Double(total) > 0.25
}

func isButtonFill(_ rgb: (Int, Int, Int)) -> Bool {
    let (r, g, b) = rgb
    if r > 220 && g > 220 && b > 220 { return false }
    let red = r > 150 && r > g + 50 && r > b + 50
    let blue = b > 130 && b > r + 35 && g > r && b < 230
    let gold = r > 190 && g > 130 && g < 235 && b < 140 && r > b + 50
    return red || blue || gold
}

func sliderIsOpen(_ words: [Word], width: Int, height: Int) -> Bool {
    let upper = words.map { (text: $0.text.uppercased(), rect: $0.rect) }
    for word in upper {
        let midX = word.rect.midX / CGFloat(width)
        let midY = word.rect.midY / CGFloat(height)
        // The ALL IN bubble sits at the top of the slider, on the right. The all-in
        // status under the stack, and the ALL IN bar along the bottom, are elsewhere.
        if midX < 0.75 || midY < 0.45 || midY > 0.75 { continue }
        if word.text == "ALL IN" { return true }
        if word.text == "ALL" {
            let paired = upper.contains { other in
                other.text == "IN"
                    && abs(other.rect.midX - word.rect.midX) < 40
                    && other.rect.minY >= word.rect.minY
                    && other.rect.minY < word.rect.maxY + 40
            }
            if paired { return true }
        }
    }
    return false
}

// One box on the table where a seat's stack, its bet, or both can appear.
struct SeatWindow {
    var seat: Int
    var x0: CGFloat
    var x1: CGFloat
    var y0: CGFloat
    var y1: CGFloat
    var bets: Bool
    var stacks: Bool
}

// Fractions of the 708x1562 mirror. The top row splits stack and bet by height.
// Your box and the bottom-left box hold both, and the coloured pill icon says which.
let seatWindows: [SeatWindow] = [
    SeatWindow(seat: 0, x0: 0.565, x1: 0.932, y0: 0.563, y1: 0.679, bets: true, stacks: true),
    SeatWindow(seat: 1, x0: 0.085, x1: 0.424, y0: 0.570, y1: 0.679, bets: true, stacks: true),
    SeatWindow(seat: 2, x0: 0.056, x1: 0.325, y0: 0.160, y1: 0.275, bets: false, stacks: true),
    SeatWindow(seat: 2, x0: 0.040, x1: 0.340, y0: 0.350, y1: 0.435, bets: true, stacks: false),
    SeatWindow(seat: 3, x0: 0.339, x1: 0.678, y0: 0.160, y1: 0.275, bets: false, stacks: true),
    SeatWindow(seat: 3, x0: 0.320, x1: 0.660, y0: 0.346, y1: 0.420, bets: true, stacks: false),
    SeatWindow(seat: 4, x0: 0.692, x1: 0.975, y0: 0.160, y1: 0.275, bets: false, stacks: true),
    SeatWindow(seat: 4, x0: 0.660, x1: 0.980, y0: 0.350, y1: 0.435, bets: true, stacks: false),
]

enum PillKind {
    case raise, call, fold
}

func readSeats(into table: inout TableRead, words: [Word], pixels: Pixels) {
    var seats = [SeatRead](repeating: SeatRead(), count: 5)
    let width = CGFloat(max(pixels.width, 1))
    let height = CGFloat(max(pixels.height, 1))
    for word in joinedAllIn(words) {
        if isSliderBubble(word, width: width, height: height) { continue }
        if isPotLabel(word, width: width, height: height) { continue }
        let x = word.rect.midX / width
        let y = word.rect.midY / height
        for window in seatWindows where x >= window.x0 && x < window.x1 && y >= window.y0 && y < window.y1 {
            noteSeatWord(word, window: window, into: &seats[window.seat], pixels: pixels)
        }
    }
    table.seats = seats
    table.dealerSeat = findDealer(pixels)
}

func joinedAllIn(_ words: [Word]) -> [Word] {
    var used = Set<Int>()
    var joined: [Word] = []
    for (index, word) in words.enumerated() {
        if used.contains(index) { continue }
        if word.text.uppercased() == "ALL" {
            if let pair = words.enumerated().first(where: { otherIndex, other in
                otherIndex != index && !used.contains(otherIndex) && other.text.uppercased() == "IN"
                    && abs(other.rect.midX - word.rect.midX) < 50
                    && other.rect.minY >= word.rect.minY - 8
                    && other.rect.minY < word.rect.maxY + 36
            }) {
                used.insert(pair.offset)
                var both = word
                both.text = "ALL IN"
                both.rect = word.rect.union(pair.element.rect)
                joined.append(both)
                continue
            }
        }
        joined.append(word)
    }
    return joined
}

func isSliderBubble(_ word: Word, width: CGFloat, height: CGFloat) -> Bool {
    let x = word.rect.midX / width
    let y = word.rect.midY / height
    guard x > 0.75, y > 0.45, y < 0.75 else { return false }
    let text = word.text.uppercased()
    return text == "ALL" || text == "IN" || text == "ALL IN"
}

func isPotLabel(_ word: Word, width: CGFloat, height: CGFloat) -> Bool {
    let x = word.rect.midX / width
    let y = word.rect.midY / height
    return x > 0.30 && x < 0.70 && y > 0.40 && y < 0.47
}

func noteSeatWord(_ word: Word, window: SeatWindow, into seat: inout SeatRead, pixels: Pixels) {
    let text = word.text.uppercased()
    if text.contains("ALL IN") || text == "ALL-IN" || text == "ALLIN" {
        if window.stacks {
            seat.allIn = true
            seat.occupied = true
        }
        return
    }
    if window.bets && text.contains("CHECK") {
        rememberAction("check", on: &seat)
        seat.occupied = true
        return
    }
    if window.bets && text.contains("FOLD") {
        rememberAction("fold", on: &seat)
        seat.folded = true
        seat.occupied = true
        return
    }
    let icon = window.bets ? pill(beside: word.rect, pixels) : nil
    if let amount = parseMoney(word.text) {
        if window.bets, let icon {
            seat.bet = max(seat.bet, amount)
            seat.occupied = true
            switch icon {
            case .raise:
                rememberAction("raise", on: &seat)
            case .call:
                rememberAction("call", on: &seat)
            case .fold:
                rememberAction("fold", on: &seat)
                seat.folded = true
            }
        } else if window.bets && !window.stacks {
            seat.bet = max(seat.bet, amount)
            seat.occupied = true
        } else if window.stacks {
            // A stack-only label can sit beside a crown. That is not a bet.
            seat.stack = max(seat.stack ?? 0, amount)
            seat.occupied = true
        }
        return
    }
    if window.bets && icon == .fold {
        rememberAction("fold", on: &seat)
        seat.folded = true
        seat.occupied = true
    } else if window.bets && icon == .call {
        rememberAction("check", on: &seat)
        seat.occupied = true
    }
}

func rememberAction(_ name: String, on seat: inout SeatRead) {
    let rank = ["check": 1, "call": 2, "raise": 3, "fold": 4]
    if rank[name, default: 0] >= rank[seat.action ?? "", default: 0] {
        seat.action = name
    }
}

// The pill icon sits just to the left of its amount. Gold is a raise, teal a call
// or a check, red a fold. A stack has none of these.
func pill(beside rect: CGRect, _ pixels: Pixels) -> PillKind? {
    guard pixels.width > 0, !pixels.bytes.isEmpty else { return nil }
    let scale = Double(pixels.width) / 708
    let outer = Int((42 * scale).rounded())
    let inner = Int((10 * scale).rounded())
    let pad = Int((18 * scale).rounded())
    let x0 = max(0, Int(rect.minX) - outer)
    let x1 = min(pixels.width - 1, Int(rect.minX) - inner)
    let y0 = max(0, Int(rect.midY) - pad)
    let y1 = min(pixels.height - 1, Int(rect.midY) + pad)
    guard x1 > x0, y1 >= y0 else { return nil }
    // A real icon is a solid block about 24 pixels square. A gold edge on the video,
    // or the felt, is a thin or sparse patch and must not count.
    struct Patch {
        var count = 0
        var minX = Int.max
        var maxX = 0
        var minY = Int.max
        var maxY = 0
        mutating func add(_ x: Int, _ y: Int) {
            count += 1
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        func solid(_ scale: Double) -> Bool {
            let needed = Int((150 * scale).rounded())
            let side = Int((12 * scale).rounded())
            guard count >= needed else { return false }
            let width = maxX - minX + 1
            let height = maxY - minY + 1
            guard width >= side, height >= side else { return false }
            return Double(count) / Double(width * height) >= 0.30
        }
    }
    var gold = Patch()
    var red = Patch()
    var teal = Patch()
    var y = y0
    while y <= y1 {
        var x = x0
        while x <= x1 {
            let (r, g, b) = pixels.rgb(x, y)
            if r > 200 && g > 160 && b < 140 && r > b + 70 {
                gold.add(x, y)
            } else if r > 190 && g < 100 && b < 110 && r > g + 90 {
                // The felt is a dull red after the colour conversion, so a fold has to be a real red.
                red.add(x, y)
            } else if g > 170 && b > 170 && r < 150 {
                teal.add(x, y)
            }
            x += 1
        }
        y += 1
    }
    let ranked: [(Patch, PillKind)] = [(gold, .raise), (red, .fold), (teal, .call)]
    guard let best = ranked.filter({ $0.0.solid(scale) }).max(by: { $0.0.count < $1.0.count }) else { return nil }
    return best.1
}

// The dealer button is a pale disc with a grey D. These five spots are where it
// sits, measured on the 708x1562 frames.
func findDealer(_ pixels: Pixels) -> Int? {
    guard pixels.width > 0, !pixels.bytes.isEmpty else { return nil }
    let anchors = [(648, 1136), (42, 1138), (172, 645), (272, 600), (486, 645)]
    var bestSeat: Int?
    var bestScore = 0.0
    for (seat, anchor) in anchors.enumerated() {
        let x = Int((Double(anchor.0) * Double(pixels.width) / 708).rounded())
        let y = Int((Double(anchor.1) * Double(pixels.height) / 1562).rounded())
        let score = dealerScore(pixels, x, y)
        if score > bestScore {
            bestScore = score
            bestSeat = seat
        }
    }
    return bestSeat
}

func dealerScore(_ pixels: Pixels, _ x: Int, _ y: Int) -> Double {
    var ringSum = 0.0
    var ringCount = 0
    var centerSum = 0.0
    var centerCount = 0
    for dy in -9...9 {
        for dx in -9...9 {
            let px = x + dx
            let py = y + dy
            guard px >= 0, py >= 0, px < pixels.width, py < pixels.height else { continue }
            let (r, g, b) = pixels.rgb(px, py)
            let gray = Double(r + g + b) / 3
            let distance = dx * dx + dy * dy
            if distance <= 9 {
                centerSum += gray
                centerCount += 1
            } else if distance >= 25 && distance <= 81 {
                ringSum += gray
                ringCount += 1
            }
        }
    }
    guard ringCount >= 20, centerCount >= 5 else { return 0 }
    let ringMean = ringSum / Double(ringCount)
    let centerMean = centerSum / Double(centerCount)
    guard ringMean >= 185, centerMean <= ringMean - 20 else { return 0 }
    return ringMean - centerMean
}

func seatReport(_ table: TableRead) -> String {
    var lines = ["seats:"]
    for (index, seat) in table.seats.enumerated() {
        let stack: String
        if seat.allIn && (seat.stack == nil || seat.stack == 0) {
            stack = "All In"
        } else if let amount = seat.stack {
            stack = formatMoney(amount) + (seat.allIn ? " All In" : "")
        } else {
            stack = "-"
        }
        let bet = seat.bet > 0 ? formatMoney(seat.bet) : "-"
        let action = seat.action ?? "-"
        let state = seat.folded ? "folded" : (seat.dealt ? "in" : "out")
        let putIn = table.invested.count == table.seats.count ? ", in \(formatMoney(table.invested[index]))" : ""
        lines.append("  \(seatNames[index]): stack \(stack), bet \(bet), \(action), \(state)\(putIn)")
    }
    let dealer = table.dealerSeat.map { seatNames[$0] } ?? "unknown"
    lines.append("  dealer: \(dealer)")
    if !table.raises.isEmpty {
        let described = table.raises.map { "\(seatNames[$0.seat]) \(formatMoney($0.total))" }.joined(separator: ", ")
        lines.append("  raises: \(described)")
    }
    return lines.joined(separator: "\n")
}

func heroStack(_ amounts: [(Double, CGRect)], width: Int, height: Int) -> Double? {
    // The stack is the amount directly above your video, on the right. Opponent stacks
    // at the same height are on the left.
    let candidates = amounts.filter { _, rect in
        let y = rect.midY / CGFloat(height)
        let x = rect.midX / CGFloat(width)
        return y > 0.56 && y < 0.70 && x > 0.52
    }
    return candidates.map(\.0).max()
}

func potAmount(_ amounts: [(Double, CGRect)], width: Int, height: Int) -> Double? {
    // The pot pill sits in the middle, just above the board. Bets sit at the sides.
    let center = CGFloat(width) / 2
    let candidates = amounts.filter { _, rect in
        let y = rect.midY / CGFloat(height)
        let x = rect.midX / CGFloat(width)
        return y > 0.40 && y < 0.47 && x > 0.30 && x < 0.70
    }
    return candidates.min { lhs, rhs in
        abs(lhs.1.midX - center) < abs(rhs.1.midX - center)
    }?.0
}

// Numbers remembered across captures. One frame's read of the pot, the blind or the stack
// is often missing or nonsense, and the advice should not follow it.
// The seat half remembers who was dealt in, who folded, and how this street was bet,
// because a later frame no longer shows the earlier action.
struct TableMemory {
    var committedBlinds: [Double] = []
    var blindForThisHand: Double?
    var handHole: [Card] = []
    var handPot: Double?
    var stack: Double?
    var pendingStack: Double?
    var pendingStackCount = 0
    var dealt = Array(repeating: false, count: 5)
    var folded = Array(repeating: false, count: 5)
    var allIn = Array(repeating: false, count: 5)
    var startStack: [Double?] = Array(repeating: nil, count: 5)
    var lastStack: [Double?] = Array(repeating: nil, count: 5)
    var streetBets = Array(repeating: 0.0, count: 5)
    var raises: [RaiseLevel] = []
    var dealer: Int?
    var boardCount = 0

    mutating func apply(to table: inout TableRead) {
        let newHand = table.hole.count == 2 && table.hole != handHole
        if newHand {
            if let blind = blindForThisHand {
                committedBlinds.append(blind)
                if committedBlinds.count > 10 { committedBlinds.removeFirst() }
            }
            blindForThisHand = nil
            handHole = table.hole
            handPot = nil
            dealt = Array(repeating: false, count: 5)
            folded = Array(repeating: false, count: 5)
            allIn = Array(repeating: false, count: 5)
            startStack = Array(repeating: nil, count: 5)
            lastStack = Array(repeating: nil, count: 5)
            streetBets = Array(repeating: 0, count: 5)
            raises = []
            // A new hand can already have board cards if the first clear frame is later.
            boardCount = table.board.count
            dealer = table.dealerSeat
        } else {
            if table.board.count > boardCount {
                streetBets = Array(repeating: 0, count: 5)
                raises = []
                boardCount = table.board.count
            }
            if let seen = table.dealerSeat { dealer = seen }
        }
        // A popup or a deal animation hides the cards. That frame's words are not the table,
        // so a "fold" or a prize in it must not stick for the rest of the hand.
        let covered = !handHole.isEmpty && table.hole.count != 2
        if !covered && table.board.isEmpty, let guess = table.bigBlind {
            blindForThisHand = guess
        }
        table.bigBlind = commonBlind()

        if !covered, let pot = table.pot {
            handPot = (newHand || handPot == nil) ? pot : max(handPot!, pot)
        }
        table.pot = handPot
        if !covered {
            table.heroStack = smoothStack(table.heroStack)
            let frame = table.seats
            if frame[0].allIn {
                stack = 0
                pendingStack = nil
                pendingStackCount = 0
                table.heroStack = 0
            }
            absorb(frame, blind: table.bigBlind, heroStack: table.heroStack)
        } else {
            table.heroStack = stack
        }
        writeBack(&table)
    }

    mutating func absorb(_ frame: [SeatRead], blind: Double?, heroStack: Double?) {
        for index in 0..<5 {
            let seen = frame[index]
            if seen.occupied { dealt[index] = true }
            if seen.folded || seen.action == "fold" { folded[index] = true }
            if seen.allIn { allIn[index] = true }
            if seen.bet > streetBets[index] { streetBets[index] = seen.bet }
            let stackRead = index == 0 ? heroStack : seen.stack
            let remaining: Double? = allIn[index] ? 0 : stackRead
            guard let remaining else { continue }
            let behind = remaining + seen.bet
            if let start = startStack[index] {
                if behind > start * 1.2 && behind < start * 3 {
                    startStack[index] = behind
                    lastStack[index] = remaining
                } else if allIn[index] || (behind >= start / 3 && behind <= start * 1.2) {
                    // A one-frame misread, such as "5,742,059" losing its leading digit, is left out.
                    lastStack[index] = remaining
                }
            } else if behind > 0 || seen.occupied || allIn[index] {
                startStack[index] = behind
                lastStack[index] = remaining
            }
        }
        let step = max((blind ?? 0) * 0.4, 1_000)
        let maxBet = streetBets.max() ?? 0
        let previous = raises.last?.total ?? 0
        guard maxBet > previous + step else { return }
        let atMax = (0..<5).filter { dealt[$0] && streetBets[$0] > 0 && streetBets[$0] >= maxBet * 0.9 }
        let aggressive = atMax.filter { frame[$0].action == "raise" || frame[$0].allIn }
        let pool = aggressive.isEmpty ? atMax : aggressive
        let chosen = pool.first { $0 != raises.last?.seat } ?? pool.first
        if let chosen {
            raises.append(RaiseLevel(seat: chosen, total: streetBets[chosen]))
        }
    }

    func writeBack(_ table: inout TableRead) {
        var invested: [Double] = []
        for index in 0..<5 {
            var seat = table.seats[index]
            seat.dealt = dealt[index]
            seat.folded = folded[index]
            seat.allIn = allIn[index]
            seat.bet = streetBets[index]
            if allIn[index] {
                seat.stack = 0
            } else if let remembered = lastStack[index] {
                seat.stack = remembered
            }
            if seat.action == nil && folded[index] { seat.action = "fold" }
            seat.occupied = dealt[index] || seat.occupied
            table.seats[index] = seat
            let remaining = seat.stack ?? 0
            let start = startStack[index] ?? remaining
            invested.append(max(0, start - remaining))
        }
        table.invested = invested
        table.raises = raises
        table.dealerSeat = dealer
    }

    func commonBlind() -> Double? {
        var values = committedBlinds
        if let blindForThisHand { values.append(blindForThisHand) }
        var best: Double?
        var bestCount = 0
        for value in values {
            let count = values.filter { abs($0 - value) / value < 0.12 }.count
            if count > bestCount {
                bestCount = count
                best = value
            }
        }
        return best
    }

    mutating func smoothStack(_ read: Double?) -> Double? {
        guard let read else { return stack }
        guard let current = stack else {
            stack = read
            return stack
        }
        let ratio = read / current
        if ratio < 3 && ratio > 1.0 / 3 {
            stack = read
            pendingStack = nil
            pendingStackCount = 0
            return stack
        }
        // A jump this large is kept only when the same figure comes back three times.
        if let pending = pendingStack, abs(read - pending) / pending < 0.15 {
            pendingStackCount += 1
        } else {
            pendingStack = read
            pendingStackCount = 1
        }
        if pendingStackCount >= 3 {
            stack = read
            pendingStack = nil
            pendingStackCount = 0
        }
        return stack
    }
}

func inferBigBlind(_ amounts: [(Double, CGRect)], hero: Double?, height: Int) -> Double? {
    // Posted blinds are the chip labels on the felt. The millions across the top are stacks,
    // and a popup full of prizes is not a pair of blinds.
    let pool = amounts.filter { amount, rect in
        let y = rect.midY / CGFloat(height)
        if y < 0.35 || y > 0.75 { return false }
        if let hero, amount > hero * 0.5 { return false }
        return amount >= 1_000
    }.map(\.0).sorted()
    var blind: Double?
    for i in 0..<pool.count {
        for j in (i + 1)..<pool.count {
            let low = pool[i]
            let high = pool[j]
            let ratio = high / low
            if ratio > 1.8 && ratio < 2.2 && (blind == nil || high < blind!) {
                blind = high
            }
        }
    }
    return blind
}

let bannedWords = ["STORE", "SALE", "BUY", "SPIN", "SAVE", "DISCOUNT", "PURCHASE", "OFFER", "PACKAGE", "FREE"]

func callAmount(_ words: [Word], callRect: CGRect?) -> Double? {
    guard let callRect else { return nil }
    let monies = words.compactMap { word -> (Double, CGRect)? in
        guard let amount = parseMoney(word.text) else { return nil }
        return (amount, word.rect)
    }
    let near = monies.filter { _, rect in
        abs(rect.midX - callRect.midX) < 90 && rect.minY >= callRect.minY - 8 && rect.midY < callRect.maxY + 36
    }
    return near.min(by: { $0.1.minY < $1.1.minY })?.0
}
