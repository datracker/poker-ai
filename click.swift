import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    print("usage: clicker <x> <y>")
    exit(1)
}
let p = CGPoint(x: x, y: y)
let src = CGEventSource(stateID: .hidSystemState)

// Move the real cursor to the target first
let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
move?.post(tap: .cghidEventTap)
usleep(150_000)

let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
down?.post(tap: .cghidEventTap)
usleep(70_000)
up?.post(tap: .cghidEventTap)
print("clicked \(Int(x)),\(Int(y))")
