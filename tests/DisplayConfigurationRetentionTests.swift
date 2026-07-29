import Foundation

struct TestDisplayConfiguration: Equatable {
    let rows: Int
    let columns: Int
}

@main
struct DisplayConfigurationRetentionTests {
    static func main() {
        let builtInID = "built-in"
        let externalID = "external"
        let known = [
            builtInID: TestDisplayConfiguration(rows: 3, columns: 7),
            externalID: TestDisplayConfiguration(rows: 5, columns: 9)
        ]
        let proposed = [
            builtInID: TestDisplayConfiguration(rows: 4, columns: 8)
        ]

        let merged = DisplayConfigurationRetention.merging(
            proposed: proposed,
            preserving: known
        )

        precondition(merged[builtInID] == proposed[builtInID], "The visible display update must win.")
        precondition(merged[externalID] == known[externalID], "The detached display must remain remembered.")
        precondition(merged.count == 2, "No display configuration may be lost during an update.")
    }
}
