import Darwin
import Foundation

// One line telling you what to tap. The bot never taps it.
// The rules are the fallback, so the line says where the advice came from.
func adviceLine(for table: TableRead) -> String {
    rulesAdviceLine(for: table)
}

func rulesAdviceLine(for table: TableRead) -> String {
    let decision = chooseAction(table)
    return painted(">>> \(actionText(decision, table))", decision.play) + "  rules: " + decision.reason
}

func rulesNote(for table: TableRead) -> String {
    let decision = chooseAction(table)
    return "    rules: \(actionText(decision, table)) — \(decision.reason)"
}

func modelAdviceLine(for table: TableRead, _ model: ModelAdvice) -> String {
    let play = playForModel(model.best)
    let action = modelActionText(table, model)
    let source = model.source == "pushfold" ? "push/fold" : "model: \(mixText(model.probs, canCheck: table.canCheck))"
    return painted(">>> \(action)", play) + "  " + source
}

func actionText(_ decision: Decision, _ table: TableRead) -> String {
    switch decision.play {
    case .fold:
        return "FOLD"
    case .check:
        return "CHECK"
    case .call:
        return callLabel(table)
    case .bet:
        return "RAISE: \(raiseLabel(table))"
    }
}

func playForModel(_ best: String) -> Play {
    switch best {
    case "fold":
        return .fold
    case "check":
        return .check
    case "call":
        return .call
    default:
        return .bet
    }
}

func modelActionText(_ table: TableRead, _ model: ModelAdvice) -> String {
    switch model.best {
    case "fold":
        return "FOLD"
    case "check":
        return "CHECK"
    case "call":
        return callLabel(table)
    case "all_in":
        return "ALL IN"
    case "half_pot":
        if table.board.isEmpty { return preflopModelRaise(table, model.raiseTo) }
        return "tap POT X0.5"
    case "pot":
        if table.board.isEmpty { return preflopModelRaise(table, model.raiseTo) }
        return "tap POT X1"
    default:
        return "FOLD"
    }
}

func preflopModelRaise(_ table: TableRead, _ raiseTo: Double?) -> String {
    guard let target = raiseTo, target > 0 else { return "RAISE" }
    if let blind = table.bigBlind, let button = nearestBlindButton(target: target, bigBlind: blind) {
        return button
    }
    return "slider to about \(formatMoney(target))"
}

func mixText(_ probs: [Double], canCheck: Bool) -> String {
    let fold = probs.count > 0 ? probs[0] : 0
    let passive = probs.count > 1 ? probs[1] : 0
    let raise = probs.dropFirst(2).reduce(0, +)
    let parts = [("fold", fold), (canCheck ? "check" : "call", passive), ("raise", raise)]
    return parts.sorted { $0.1 > $1.1 }.map { "\($0.0) \(Int(($0.1 * 100).rounded()))%" }.joined(separator: ", ")
}

func unreadableLine() -> String {
    let text = ">>> cards not readable, decide yourself"
    guard isatty(STDOUT_FILENO) != 0 else { return text }
    return "\u{1B}[1m\(text)\u{1B}[0m"
}

func callLabel(_ table: TableRead) -> String {
    if table.toCall > 0 && table.toCall < 1e15 {
        return "CALL \(formatMoney(table.toCall))"
    }
    return "CALL"
}

func raiseLabel(_ table: TableRead) -> String {
    if table.board.isEmpty { return preflopRaise(table) }
    let made = showdown(table.hole, table.board)
    if made.tier >= .strong { return "tap POT X0.75" }
    return "tap POT X0.5"
}

// Opening, or raising when it was checked to you, uses the BB X4 button.
// A 3-bet is about three times the bet in front: a BB button when one is close, otherwise the slider.
func preflopRaise(_ table: TableRead) -> String {
    let whereWeAre = spot(
        toCall: table.toCall,
        bigBlind: table.bigBlind,
        stack: table.heroStack,
        canCheck: table.canCheck
    )
    guard whereWeAre == .facingOpen, table.toCall > 0, table.toCall < 1e15 else {
        return "tap BB X4"
    }
    let target = table.toCall * 3
    if let bb = table.bigBlind, let button = nearestBlindButton(target: target, bigBlind: bb) {
        return button
    }
    return "slider to about \(formatMoney(target))"
}

// BB X4, X6 or X8, when one of them lands within a quarter of the raise.
func nearestBlindButton(target: Double, bigBlind: Double) -> String? {
    guard target > 0, bigBlind > 0 else { return nil }
    let choices = [("BB X4", bigBlind * 4), ("BB X6", bigBlind * 6), ("BB X8", bigBlind * 8)]
    guard let best = choices.min(by: { abs($0.1 - target) < abs($1.1 - target) }),
          abs(best.1 - target) / target <= 0.25 else { return nil }
    return "tap \(best.0)"
}

func painted(_ text: String, _ play: Play) -> String {
    guard isatty(STDOUT_FILENO) != 0 else { return text }
    let color: String
    switch play {
    case .fold: color = "31"
    case .check, .call: color = "32"
    case .bet: color = "33"
    }
    return "\u{1B}[1;\(color)m\(text)\u{1B}[0m"
}
