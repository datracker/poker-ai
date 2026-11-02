import CoreGraphics
import Foundation
import ImageIO

struct MirrorWindow {
    var id: CGWindowID
    var bounds: CGRect
}

let args = CommandLine.arguments
if args.contains("--self-test") {
    let failures = runStrategyTests()
    if failures.isEmpty {
        print("strategy tests passed")
        exit(0)
    }
    for failure in failures { fputs("failed: \(failure)\n", stderr) }
    exit(1)
}

let once = args.contains("--once")
let imagePath = argumentValue("--image")
let replayFolder = argumentValue("--replay")

fputs("Advice only. When it is your turn it prints what to do, and you tap it yourself.\n", stderr)
fputs("Ctrl-C stops it.\n", stderr)

let livePath = "/tmp/pokerbot-live.png"
let continuous = imagePath == nil && !once
let replaying = replayFolder != nil
let showSeats = imagePath != nil || replaying
let compareAdvice = showSeats
let projectDirectory = (Bundle.main.executableURL ?? URL(fileURLWithPath: args[0])).deletingLastPathComponent()
let cardReader = CardReader(projectDirectory: projectDirectory)
if let hint = cardReader.setupHint {
    fputs("Cannot read cards: \(hint)\n", stderr)
    exit(1)
}
let advisor = AdvisorClient(projectDirectory: projectDirectory)
if let hint = advisor.setupHint {
    fputs("Model unavailable (\(hint)). Advice will use the built-in rules.\n", stderr)
}

var memory = TableMemory()
var lastSummary = ""
var lastSeats = ""
var lastRead = ""
var lastSituation = ""
var awayCount = 0
var unclearCount = 0
var pollDelay = 0.7

if let imagePath {
    guard let image = loadImage(imagePath) else {
        fputs("Could not read \(imagePath)\n", stderr)
        exit(1)
    }
    act(on: image, path: URL(fileURLWithPath: imagePath).path)
    exit(0)
}

if let replayFolder {
    let folder = URL(fileURLWithPath: replayFolder, isDirectory: true)
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    let frames = files.filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    if frames.isEmpty {
        fputs("No frames in \(replayFolder)\n", stderr)
        exit(1)
    }
    for frame in frames {
        guard let image = loadImage(frame.path) else { continue }
        act(on: image, path: frame.path)
    }
    exit(0)
}

while true {
    guard let window = findMirror() else {
        fputs("iPhone Mirroring is not open.\n", stderr)
        if once { exit(1) }
        Thread.sleep(forTimeInterval: 1.5)
        continue
    }
    guard let image = capture(window) else {
        fputs("Could not capture the mirror. Allow Screen Recording for the terminal running this program.\n", stderr)
        if once { exit(1) }
        Thread.sleep(forTimeInterval: 1.5)
        continue
    }
    act(on: image, path: livePath)
    if once { break }
    Thread.sleep(forTimeInterval: pollDelay)
}

func act(on image: CGImage, path: String) {
    var table = readTable(image, path: path, cards: cardReader)
    pollDelay = (table.ourTurn || table.sliderOpen) ? 0.4 : 0.7
    let seats = showSeats ? seatReport(table) : nil
    // The slider hides your cards and your stack, so this frame cannot change the advice.
    if table.sliderOpen {
        if !continuous || showSeats { report(headline(path, table.summary), seats: seats) }
        return
    }
    memory.apply(to: &table)
    // Cards slide, flip and fade for a capture or two. A read counts once the next capture agrees.
    // A replay is already one frame at a time, so each frame counts.
    let read = "\(table.hole)|\(table.board)|\(table.cardProblems.isEmpty)|\(table.ourTurn)|\(Int(table.toCall))|\(table.canCheck)"
    let steady = !continuous || replaying || read == lastRead
    lastRead = read
    if steady { report(headline(path, table.summary), seats: showSeats ? seatReport(table) : nil) }
    guard table.ourTurn else {
        if steady { awayCount += 1 }
        if awayCount >= 2 {
            lastSituation = ""
            unclearCount = 0
        }
        return
    }
    awayCount = 0
    let unclear = !table.cardProblems.isEmpty || table.hole.count < 2 || (table.board.count > 0 && table.board.count < 3)
    if unclear {
        unclearCount += 1
        if (!continuous || unclearCount >= 3) && lastSituation != "unclear" {
            print(unreadableLine())
            lastSituation = "unclear"
        }
        return
    }
    unclearCount = 0
    guard steady else { return }
    let ready = modelInputsReady(table)
    let model = ready ? advisor.advise(table) : nil
    let folds = table.seats.map { $0.folded ? "f" : ($0.bet > 0 ? "b" : "-") }.joined()
    let situation = "\(table.hole)|\(table.board)|\(Int(table.toCall))|\(table.canCheck)|\(table.dealerSeat.map(String.init) ?? "-")|\(table.raises)|\(folds)|\(model?.best ?? "rules")"
    if situation == lastSituation { return }
    if let model {
        print(modelAdviceLine(for: table, model))
        if compareAdvice { print(rulesNote(for: table)) }
    } else {
        print(adviceLine(for: table))
    }
    lastSituation = situation
}

func headline(_ path: String, _ summary: String) -> String {
    guard replaying else { return summary }
    return "\(URL(fileURLWithPath: path).lastPathComponent)  \(summary)"
}

func report(_ summary: String, seats: String? = nil) {
    if summary != lastSummary {
        print(summary)
        lastSummary = summary
    }
    if let seats, seats != lastSeats {
        print(seats)
        lastSeats = seats
    }
}

func findMirror() -> MirrorWindow? {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var best: MirrorWindow?
    var bestArea: CGFloat = 0
    for window in info {
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        guard owner == "iPhone Mirroring" else { continue }
        guard let bounds = window[kCGWindowBounds as String] as? NSDictionary else { continue }
        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(bounds, &rect), rect.width > 80, rect.height > 200 else { continue }
        let number = window[kCGWindowNumber as String] as? Int ?? 0
        let area = rect.width * rect.height
        if area > bestArea {
            bestArea = area
            best = MirrorWindow(id: CGWindowID(number), bounds: rect)
        }
    }
    return best
}

func capture(_ window: MirrorWindow) -> CGImage? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-l", String(window.id), "-x", "-o", livePath]
    do { try process.run() } catch { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return loadImage(livePath)
}

func loadImage(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func argumentValue(_ flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), args.count > index + 1 else { return nil }
    return args[index + 1]
}
