import Foundation

/// Persists the day plan, so a plan survives quitting and is there tomorrow.
struct DayPlanStore {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DayPlan {
        guard let data = defaults.data(forKey: AppStorageKey.dayPlan),
              let plan = try? JSONDecoder().decode(DayPlan.self, from: data) else {
            return DayPlan()
        }
        return plan
    }

    func save(_ plan: DayPlan) {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        defaults.set(data, forKey: AppStorageKey.dayPlan)
    }
}
