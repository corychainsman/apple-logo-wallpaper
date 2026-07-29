import Foundation

enum DisplayConfigurationRetention {
    static func merging<Value>(
        proposed: [String: Value],
        preserving known: [String: Value]
    ) -> [String: Value] {
        known.merging(proposed) { _, proposedValue in proposedValue }
    }
}
