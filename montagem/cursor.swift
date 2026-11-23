import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]), let y = Double(CommandLine.arguments[2]),
      x.isFinite, y.isFinite else { exit(2) }
guard CGWarpMouseCursorPosition(CGPoint(x: x, y: y)) == .success else { exit(3) }
