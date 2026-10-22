import Foundation

/// Player ⋯ menu "Sleep timer", like the YouTube app: pause after a while, or when the current
/// video ends. Not persisted — every app session starts with it off.
enum SleepTimer: Hashable, Identifiable {
    case off
    case minutes(Int)
    case endOfVideo

    static let choices: [SleepTimer] = [.off, .minutes(10), .minutes(15), .minutes(20), .minutes(30), .minutes(45), .minutes(60), .endOfVideo]

    var id: Self { self }
}
