@testable import SourceKitXcodeBSP

/// Fixed-value test double. `set` is a no-op — extend with recording if a future
/// test needs to assert on writes.
struct FakeEnvironmentRepository: EnvironmentRepository {
    let values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func get(_ key: String) -> String? {
        values[key]
    }

    func set(_ key: String, value: String, overwrite: Bool) {}
}
