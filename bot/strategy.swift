import Foundation

// Short-stack Hold'em for this app.
// Stacks here are usually about 25–40 big blinds, and the opponents call too wide.
// So the bot uses a modern raise-or-fold opening range, continues with real equity,
// value-bets made hands, and does not bluff air.

enum Suit: Int, CaseIterable {
    case clubs, diamonds, hearts, spades

    var symbol: String {
        switch self {
        case .clubs: return "♣️"
        case .diamonds: return "♦️"
        case .hearts: return "♥️"
        case .spades: return "♠️"
        }
    }
}

struct Card: Hashable, CustomStringConvertible {
    var rank: Int // 2...14
    var suit: Suit

    var description: String { "\(Card.rankName(rank))\(suit.symbol)" }

    static func rankName(_ rank: Int) -> String {
        if rank == 10 { return "10" }
        return rankLetter(rank)
    }

    static func rankLetter(_ rank: Int) -> String {
        let letters = ["2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K", "A"]
        guard (2...14).contains(rank) else { return "?" }
        return letters[rank - 2]
    }

    static func rankValue(_ text: String) -> Int? {
        switch text.uppercased() {
        case "2": return 2
        case "3": return 3
        case "4": return 4
        case "5": return 5
        case "6": return 6
        case "7": return 7
        case "8": return 8
        case "9": return 9
        case "10", "T": return 10
        case "J": return 11
        case "Q": return 12
        case "K": return 13
        case "A": return 14
        default: return nil
        }
    }
}

enum Play: String {
    case fold, check, call, bet
}

struct Decision {
    var play: Play
    var reason: String
}

enum HandTier: Int, Comparable {
    case air, draw, weak, medium, strong, monster

    static func < (lhs: HandTier, rhs: HandTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

func handCode(_ hole: [Card]) -> String? {
    guard hole.count == 2 else { return nil }
    let a = hole[0], b = hole[1]
    let hi = max(a.rank, b.rank)
    let lo = min(a.rank, b.rank)
    if hi == lo { return "\(Card.rankLetter(hi))\(Card.rankLetter(lo))" }
    let suited = a.suit == b.suit ? "s" : "o"
    return "\(Card.rankLetter(hi))\(Card.rankLetter(lo))\(suited)"
}

func inRange(_ code: String, _ spec: String) -> Bool {
    for raw in spec.split(separator: ",") {
        let part = raw.trimmingCharacters(in: .whitespaces)
        if part.isEmpty { continue }
        if matchRange(code, part) { return true }
    }
    return false
}

private func matchRange(_ code: String, _ spec: String) -> Bool {
    let plus = spec.hasSuffix("+")
    let token = plus ? String(spec.dropLast()) : spec
    if !plus { return code == token }
    if code.count < 2 || token.count < 2 { return false }
    let codeRanks = ranks(in: code)
    let specRanks = ranks(in: token)
    guard codeRanks.count == 2, specRanks.count == 2 else { return false }
    let codeSuited = code.hasSuffix("s")
    let specSuited = token.hasSuffix("s")
    let codeOff = code.hasSuffix("o")
    let specOff = token.hasSuffix("o")
    if codeRanks[0] == codeRanks[1] {
        // Pair plus: "77+" matches 77 and above.
        return specRanks[0] == specRanks[1] && codeRanks[0] >= specRanks[0]
    }
    if specRanks[0] == specRanks[1] { return false }
    if codeSuited != specSuited || codeOff != specOff { return false }
    return codeRanks[0] == specRanks[0] && codeRanks[1] >= specRanks[1]
}

private func ranks(in code: String) -> [Int] {
    var values: [Int] = []
    var rest = code
    if rest.hasSuffix("s") || rest.hasSuffix("o") { rest.removeLast() }
    if rest == "10" { return [10] }
    // "ATs" -> A, T. "TT" -> T, T. A ten only appears as T in our codes.
    for ch in rest {
        if let v = Card.rankValue(String(ch)) { values.append(v) }
    }
    return values
}

private let openRange = "22+,A4s+,K9s+,Q9s+,J9s+,T8s+,97s+,86s+,76s,65s,ATo+,KJo+,QJo"
private let shortOpenRange = "22+,A2s+,A8o+,K9s+,KTo+,QTs+,JTs,T9s,98s"
private let threeBetRange = "TT+,AJs+,AQs+,AKo"
private let openCallRange = "77+,ATs,AJo,KQs,KJs,QJs,JTs,AQo"
private let largeContinueRange = "QQ+,AKs,AKo"

enum Spot {
    case checkedTo
    case unopened
    case facingOpen
    case facingLarge
}

func spot(toCall: Double, bigBlind: Double?, stack: Double?, canCheck: Bool) -> Spot {
    if canCheck || toCall <= 0 { return .checkedTo }
    if let bb = bigBlind, bb > 0 {
        let bets = toCall / bb
        if bets <= 1.25 { return .unopened }
        if bets <= 5.5 { return .facingOpen }
        return .facingLarge
    }
    let chips = stack ?? 0
    if chips > 0 {
        let frac = toCall / chips
        if frac <= 0.05 { return .unopened }
        if frac <= 0.16 { return .facingOpen }
        return .facingLarge
    }
    return .facingOpen
}

func preflopDecision(hole: [Card], toCall: Double, bigBlind: Double?, stack: Double?, canCheck: Bool) -> Decision {
    guard let code = handCode(hole) else {
        return Decision(play: canCheck ? .check : .fold, reason: "could not read both hole cards")
    }
    let stackBB: Double = {
        guard let bb = bigBlind, bb > 0, let stack, stack > 0 else { return 30 }
        return stack / bb
    }()
    let whereWeAre = spot(toCall: toCall, bigBlind: bigBlind, stack: stack, canCheck: canCheck)
    switch whereWeAre {
    case .checkedTo:
        let raiseRange = stackBB <= 15 ? shortOpenRange : "99+,AJs+,AQo+,KQs"
        if inRange(code, raiseRange) {
            return Decision(play: .bet, reason: "\(code) raises when checked to, \(fmtBB(stackBB)) behind")
        }
        return Decision(play: .check, reason: "\(code) checks back")
    case .unopened:
        let range = stackBB <= 15 ? shortOpenRange : openRange
        if inRange(code, range) {
            return Decision(play: .bet, reason: "\(code) opens, no raise in front, \(fmtBB(stackBB)) behind")
        }
        return Decision(play: .fold, reason: "\(code) folds unopened. Calling one blind would be a limp")
    case .facingOpen:
        if inRange(code, threeBetRange) {
            return Decision(play: .bet, reason: "\(code) 3-bets a normal open")
        }
        if inRange(code, openCallRange) {
            return Decision(play: .call, reason: "\(code) calls a normal open")
        }
        return Decision(play: .fold, reason: "\(code) folds to an open")
    case .facingLarge:
        if inRange(code, largeContinueRange) {
            return Decision(play: .call, reason: "\(code) continues against a large raise")
        }
        return Decision(play: .fold, reason: "\(code) folds to a large raise")
    }
}

private func fmtBB(_ n: Double) -> String {
    String(format: "%.0fbb", n)
}

// MARK: - Evaluator

enum Category: Int, Comparable {
    case high = 0, pair, twoPair, trips, straight, flush, fullHouse, quads, straightFlush

    static func < (lhs: Category, rhs: Category) -> Bool { lhs.rawValue < rhs.rawValue }
}

func bestScore(_ cards: [Card]) -> Int {
    guard !cards.isEmpty else { return 0 }
    if cards.count <= 5 { return score(cards) }
    var best = 0
    for combo in combinations(cards.count, min(5, cards.count)) {
        let five = combo.map { cards[$0] }
        best = max(best, score(five))
    }
    return best
}

func category(of cards: [Card]) -> Category {
    Category(rawValue: bestScore(cards) >> 20) ?? .high
}

private func score(_ cards: [Card]) -> Int {
    let ranks = cards.map(\.rank).sorted(by: >)
    let flush = Set(cards.map(\.suit)).count == 1 && cards.count >= 5
    let grouped = Dictionary(grouping: ranks, by: { $0 }).map { ($0.key, $0.value.count) }
    let byCount = grouped.sorted { a, b in
        if a.1 != b.1 { return a.1 > b.1 }
        return a.0 > b.0
    }
    let straightHigh = straightHighCard(ranks)

    if flush, let high = straightHigh, cards.count >= 5 {
        return pack(.straightFlush, [high])
    }
    if byCount.first?.1 == 4 {
        let quad = byCount[0].0
        let kicker = byCount.dropFirst().map(\.0).max() ?? 0
        return pack(.quads, [quad, kicker])
    }
    if byCount.count >= 2, byCount[0].1 == 3, byCount[1].1 >= 2 {
        return pack(.fullHouse, [byCount[0].0, byCount[1].0])
    }
    if flush {
        return pack(.flush, ranks)
    }
    if let high = straightHigh, cards.count >= 5 {
        return pack(.straight, [high])
    }
    if byCount.first?.1 == 3 {
        let kickers = byCount.dropFirst().map(\.0).sorted(by: >)
        return pack(.trips, [byCount[0].0] + kickers)
    }
    if byCount.count >= 2, byCount[0].1 == 2, byCount[1].1 == 2 {
        let kicker = byCount.dropFirst(2).map(\.0).max() ?? 0
        return pack(.twoPair, [byCount[0].0, byCount[1].0, kicker])
    }
    if byCount.first?.1 == 2 {
        let kickers = byCount.dropFirst().map(\.0).sorted(by: >)
        return pack(.pair, [byCount[0].0] + kickers)
    }
    return pack(.high, ranks)
}

private func pack(_ cat: Category, _ kickers: [Int]) -> Int {
    var value = cat.rawValue << 20
    for (i, kicker) in kickers.prefix(5).enumerated() {
        value += kicker << ((4 - i) * 4)
    }
    return value
}

private func straightHighCard(_ ranks: [Int]) -> Int? {
    var set = Set(ranks)
    if set.contains(14) { set.insert(1) }
    let unique = set.sorted(by: >)
    if unique.count < 5 && !unique.contains(1) { return nil }
    // Windows of five consecutive ranks. Ace-high down through the wheel.
    for high in stride(from: 14, through: 5, by: -1) {
        let window = (0..<5).map { high - $0 }
        if window.allSatisfy({ set.contains($0 == 1 ? 1 : $0) }) {
            return high
        }
    }
    return nil
}

private func combinations(_ n: Int, _ k: Int) -> [[Int]] {
    if k == 0 { return [[]] }
    if n < k { return [] }
    var result: [[Int]] = []
    var stack: [Int] = []
    func walk(_ start: Int) {
        if stack.count == k {
            result.append(stack)
            return
        }
        let remain = k - stack.count
        if start > n - remain { return }
        for i in start..<(n - remain + 1) {
            stack.append(i)
            walk(i + 1)
            stack.removeLast()
        }
    }
    walk(0)
    return result
}

struct Showdown {
    var tier: HandTier
    var label: String
    var outs: Int
}

func showdown(_ hole: [Card], _ board: [Card]) -> Showdown {
    let outs = drawOuts(hole, board)
    guard hole.count == 2, !board.isEmpty else {
        return Showdown(tier: outs >= 8 ? .draw : .air, label: "incomplete", outs: outs)
    }
    let cat = category(of: hole + board)
    let label = madeLabel(hole, board, cat)
    let tier = tierFor(hole, board, cat, outs)
    return Showdown(tier: tier, label: label, outs: outs)
}

private func madeLabel(_ hole: [Card], _ board: [Card], _ cat: Category) -> String {
    switch cat {
    case .straightFlush: return "straight flush"
    case .quads: return "quads"
    case .fullHouse: return "full house"
    case .flush: return "flush"
    case .straight: return "straight"
    case .trips: return "trips"
    case .twoPair: return "two pair"
    case .pair: return pairLabel(hole, board)
    case .high: return "high card"
    }
}

private func pairLabel(_ hole: [Card], _ board: [Card]) -> String {
    if hole[0].rank == hole[1].rank {
        if hole[0].rank > (board.map(\.rank).max() ?? 0) { return "overpair" }
        return "underpair"
    }
    let boardRanks = Set(board.map(\.rank))
    let paired = hole.map(\.rank).filter { boardRanks.contains($0) }
    guard let pairRank = paired.max() else { return "board pair" }
    let uniqueBoard = Array(boardRanks).sorted(by: >)
    if pairRank == uniqueBoard.first { return "top pair" }
    if uniqueBoard.count > 1, pairRank == uniqueBoard[1] { return "second pair" }
    return "bottom pair"
}

private func tierFor(_ hole: [Card], _ board: [Card], _ cat: Category, _ outs: Int) -> HandTier {
    if !holePlays(hole, board, cat) {
        return outs >= 8 ? .draw : .weak
    }
    switch cat {
    case .straightFlush, .quads, .fullHouse, .flush, .straight, .trips:
        return .monster
    case .twoPair:
        return .strong
    case .pair:
        let name = pairLabel(hole, board)
        if name == "overpair" { return .strong }
        if name == "top pair" {
            let boardRanks = Set(board.map(\.rank))
            let kicker = hole.map(\.rank).filter { !boardRanks.contains($0) }.max() ?? 0
            return kicker >= 12 ? .strong : .medium
        }
        if name == "second pair" { return .medium }
        return .weak
    case .high:
        return outs >= 8 ? .draw : (outs >= 4 ? .weak : .air)
    }
}

private func holePlays(_ hole: [Card], _ board: [Card], _ cat: Category) -> Bool {
    switch cat {
    case .flush, .straightFlush:
        let suits = Dictionary(grouping: hole + board, by: \.suit)
        guard let flushSuit = suits.first(where: { $0.value.count >= 5 })?.key else { return false }
        return hole.contains { $0.suit == flushSuit }
    case .pair, .twoPair, .trips, .fullHouse, .quads:
        if hole[0].rank == hole[1].rank { return true }
        let boardRanks = Set(board.map(\.rank))
        return hole.contains { boardRanks.contains($0.rank) }
    case .straight:
        return hole.contains { card in
            var trial = board
            trial.append(card)
            return category(of: trial) >= .straight || bestScore(trial) > bestScore(board)
        }
    case .high:
        return false
    }
}

func drawOuts(_ hole: [Card], _ board: [Card]) -> Int {
    guard hole.count == 2, (3...4).contains(board.count) else { return 0 }
    var outCards = Set<Int>() // rank * 4 + suit
    let seen = hole + board
    func key(_ rank: Int, _ suit: Suit) -> Int { rank * 4 + suit.rawValue }
    let seenKeys = Set(seen.map { key($0.rank, $0.suit) })

    // Flush outs: exactly four of one suit, and at least one is in the hole.
    let bySuit = Dictionary(grouping: seen, by: \.suit)
    for (suit, cards) in bySuit where cards.count == 4 && hole.contains(where: { $0.suit == suit }) {
        for rank in 2...14 {
            let k = key(rank, suit)
            if !seenKeys.contains(k) { outCards.insert(k) }
        }
    }

    // Straight outs: one unseen rank completes a straight that uses a hole card.
    let have = Set(seen.map(\.rank))
    for rank in 2...14 where !have.contains(rank) {
        for suit in Suit.allCases {
            let k = key(rank, suit)
            if seenKeys.contains(k) { continue }
            let extra = Card(rank: rank, suit: suit)
            if completesStraight(hole: hole, board: board, extra: extra) {
                outCards.insert(k)
            }
        }
    }
    return outCards.count
}

private func completesStraight(hole: [Card], board: [Card], extra: Card) -> Bool {
    let with = hole + board + [extra]
    guard category(of: with) >= .straight else { return false }
    // The straight has to use at least one hole card, not just the board plus the extra card.
    let boardPlus = board + [extra]
    if board.count + 1 >= 5 && category(of: boardPlus) >= .straight { return false }
    return true
}

func equity(outs: Int, boardCount: Int) -> Double {
    if outs <= 0 { return 0 }
    if boardCount <= 3 {
        let miss1 = 1 - Double(outs) / 47
        let miss2 = 1 - Double(outs) / 46
        return 1 - miss1 * miss2
    }
    return Double(outs) / 46
}

func postflopDecision(
    hole: [Card],
    board: [Card],
    toCall: Double,
    pot: Double,
    canCheck: Bool
) -> Decision {
    let made = showdown(hole, board)
    // The center pot usually does not include the unmatched bet still in front of a player.
    let price = toCall <= 0 ? 0 : toCall / (pot + toCall + toCall)
    let drawEquity = equity(outs: made.outs, boardCount: board.count)
    let code = handCode(hole) ?? "?"

    if canCheck || toCall <= 0 {
        if made.tier >= .strong {
            return Decision(play: .bet, reason: "\(code) bets \(made.label) for value")
        }
        if made.tier == .draw && made.outs >= 12 {
            return Decision(play: .bet, reason: "\(code) bets a combo draw (\(made.outs) outs)")
        }
        return Decision(play: .check, reason: "\(code) checks \(made.label)")
    }

    if pot <= 0 && made.tier < .monster {
        return Decision(play: .fold, reason: "\(code) folds because the pot could not be read")
    }

    switch made.tier {
    case .monster:
        return Decision(play: .call, reason: "\(code) calls with \(made.label)")
    case .strong:
        if price <= 0.42 {
            return Decision(play: .call, reason: "\(code) calls a \(pct(price)) bet with \(made.label)")
        }
        return Decision(play: .fold, reason: "\(code) folds \(made.label) to a \(pct(price)) bet")
    case .medium:
        if price <= 0.25 || drawEquity >= price {
            return Decision(play: .call, reason: "\(code) calls a small bet with \(made.label)")
        }
        return Decision(play: .fold, reason: "\(code) folds \(made.label). The bet is \(pct(price)) of the pot")
    case .draw, .weak:
        if drawEquity > 0, drawEquity >= price {
            return Decision(play: .call, reason: "\(code) calls \(made.label) with \(made.outs) outs (\(pct(drawEquity)) vs \(pct(price)))")
        }
        if made.tier == .weak && price <= 0.15 {
            return Decision(play: .call, reason: "\(code) calls a tiny bet with \(made.label)")
        }
        return Decision(play: .fold, reason: "\(code) folds \(made.label)")
    case .air:
        if drawEquity >= price && drawEquity > 0 {
            return Decision(play: .call, reason: "\(code) calls a draw, \(made.outs) outs")
        }
        return Decision(play: .fold, reason: "\(code) folds \(made.label)")
    }
}

private func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }

func runStrategyTests() -> [String] {
    var failures: [String] = []
    func check(_ ok: Bool, _ name: String) {
        if !ok { failures.append(name) }
    }

    let ah = Card(rank: 14, suit: .hearts)
    let kh = Card(rank: 13, suit: .hearts)
    let kd = Card(rank: 13, suit: .diamonds)
    let qs = Card(rank: 12, suit: .spades)
    let js = Card(rank: 11, suit: .spades)
    let ts = Card(rank: 10, suit: .spades)
    let nine = Card(rank: 9, suit: .clubs)
    let two = Card(rank: 2, suit: .clubs)
    let five = Card(rank: 5, suit: .spades)
    let aceS = Card(rank: 14, suit: .spades)
    let fourS = Card(rank: 4, suit: .spades)
    let eightH = Card(rank: 8, suit: .hearts)
    let twoD = Card(rank: 2, suit: .diamonds)

    check(category(of: [ah, kh, qs, js, ts]) == .straight, "broadway straight")
    check(category(of: [Card(rank: 14, suit: .clubs), Card(rank: 2, suit: .diamonds), Card(rank: 3, suit: .hearts), Card(rank: 4, suit: .spades), Card(rank: 5, suit: .clubs)]) == .straight, "wheel")
    check(category(of: [ah, kh, Card(rank: 12, suit: .hearts), Card(rank: 11, suit: .hearts), Card(rank: 10, suit: .hearts)]) == .straightFlush, "royal")
    check(inRange("72o", openRange) == false, "72o not an open")
    check(inRange("AKs", openRange), "AKs opens")
    check(inRange("76s", openRange), "76s opens")
    check(inRange("22", openRange), "22 opens")
    check(inRange("A9o", openRange) == false, "A9o does not open from an unknown seat")

    let foldJunk = preflopDecision(hole: [two, five], toCall: 200_000, bigBlind: 200_000, stack: 5_700_000, canCheck: false)
    check(foldJunk.play == .fold, "25o folds to the blind, got \(foldJunk.play)")

    let openAK = preflopDecision(hole: [ah, kd], toCall: 200_000, bigBlind: 200_000, stack: 5_700_000, canCheck: false)
    check(openAK.play == .bet, "AKo opens, got \(openAK.play)")

    let made = showdown([two, five], [fourS, eightH, twoD])
    check(made.label == "bottom pair", "2-5 on 4-8-2 is bottom pair, got \(made.label)")
    let foldBottom = postflopDecision(hole: [two, five], board: [fourS, eightH, twoD], toCall: 600_000, pot: 2_400_000, canCheck: false)
    check(foldBottom.play == .fold, "bottom pair folds to 600k into 2.4m, got \(foldBottom.play)")

    let twoPair = showdown([aceS, kd], [ah, kh, twoD])
    check(twoPair.tier >= .strong, "aces and kings is strong, got \(twoPair.label)")

    let flushDraw = drawOuts([ah, Card(rank: 5, suit: .hearts)], [kh, Card(rank: 9, suit: .hearts), twoD])
    check(flushDraw == 9, "flush draw has 9 outs, got \(flushDraw)")

    let callDraw = postflopDecision(
        hole: [ah, Card(rank: 5, suit: .hearts)],
        board: [kh, Card(rank: 9, suit: .hearts), twoD],
        toCall: 100,
        pot: 300,
        canCheck: false
    )
    check(callDraw.play == .call, "flush draw calls a small bet, got \(callDraw.play) \(callDraw.reason)")

    _ = nine
    _ = qs
    return failures
}
