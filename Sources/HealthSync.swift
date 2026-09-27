import Foundation
import HealthKit
import BackgroundTasks

/// Reads Apple Health (which includes what the Watch records) and posts one summary per day.
/// Days that could not be sent stay in a queue and are retried on every wake.
final class HealthSync: ObservableObject {
    static let shared = HealthSync()

    @Published private(set) var isPaired = false
    @Published private(set) var needsRepair = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var daysSent = 0
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false

    private let store = HKHealthStore()
    private let config = AppConfig.shared
    private let defaults = UserDefaults.standard
    private let gate = SyncGate()
    private var observing = false
    private var bgRegistered = false

    private var refreshId: String { (Bundle.main.bundleIdentifier ?? "litewrap") + ".refresh" }

    // MARK: What can be read

    enum Kind {
        case sum(HKQuantityTypeIdentifier, HKUnit)
        case latest(HKQuantityTypeIdentifier, HKUnit, Double)
        case workouts
    }

    static let catalog: [String: Kind] = [
        "active": .sum(.activeEnergyBurned, .kilocalorie()),
        "resting": .sum(.basalEnergyBurned, .kilocalorie()),
        "steps": .sum(.stepCount, .count()),
        "exerciseMinutes": .sum(.appleExerciseTime, .minute()),
        "rhr": .latest(.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), 1),
        "weight": .latest(.bodyMass, .gramUnit(with: .kilo), 1),
        "bodyFat": .latest(.bodyFatPercentage, .percent(), 100),
        "workouts": .workouts
    ]

    private var fields: [String] { config.health.types.filter { Self.catalog[$0] != nil } }

    private var sampleTypes: [HKSampleType] {
        fields.compactMap { field -> HKSampleType? in
            switch Self.catalog[field]! {
            case .sum(let id, _), .latest(let id, _, _):
                return HKQuantityType.quantityType(forIdentifier: id)
            case .workouts:
                return HKObjectType.workoutType()
            }
        }
    }

    private init() {
        isPaired = Keychain.get("token") != nil && Keychain.get("syncUrl") != nil
        needsRepair = defaults.bool(forKey: "lw.needsRepair")
        lastSync = defaults.object(forKey: "lw.lastSync") as? Date
        daysSent = defaults.integer(forKey: "lw.daysSent")
        pendingCount = pending.count
    }

    private var pending: [String] {
        get { defaults.stringArray(forKey: "lw.pending") ?? [] }
        set {
            // Keep at most the last 30 days in the queue.
            let trimmed = Array(Set(newValue)).sorted().suffix(30)
            defaults.set(Array(trimmed), forKey: "lw.pending")
            let count = trimmed.count
            DispatchQueue.main.async { self.pendingCount = count }
        }
    }

    // MARK: Pairing

    func pair(token: String, url: String, done: @escaping () -> Void) {
        Keychain.set(token, "token")
        Keychain.set(url, "syncUrl")
        defaults.set(false, forKey: "lw.needsRepair")
        DispatchQueue.main.async {
            self.isPaired = true
            self.needsRepair = false
            self.lastError = nil
        }
        requestAuthorization {
            self.startObserving()
            self.syncRecent(days: 7)
            DispatchQueue.main.async { done() }
        }
    }

    func unpair() {
        Keychain.delete("token")
        Keychain.delete("syncUrl")
        store.disableAllBackgroundDelivery { _, _ in }
        pending = []
        DispatchQueue.main.async { self.isPaired = false }
    }

    private func requestAuthorization(_ done: @escaping () -> Void) {
        guard config.health.enabled, HKHealthStore.isHealthDataAvailable() else { return done() }
        let read = Set(sampleTypes.map { $0 as HKObjectType })
        store.requestAuthorization(toShare: nil, read: read) { _, _ in done() }
    }

    // MARK: Background

    func startObservingIfPaired() {
        if isPaired { startObserving() }
    }

    private func startObserving() {
        guard config.health.enabled, HKHealthStore.isHealthDataAvailable(), !observing else { return }
        observing = true
        for type in sampleTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard let self, error == nil else { completion(); return }
                Task {
                    await self.run(self.daysForWake())
                    completion()
                }
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    func registerBackgroundTask() {
        guard !bgRegistered else { return }
        bgRegistered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshId, using: nil) { [weak self] task in
            guard let self else { task.setTaskCompleted(success: true); return }
            self.scheduleRefresh()
            let work = Task {
                await self.run(self.daysForWake())
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    func scheduleRefresh() {
        guard config.health.enabled, isPaired else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Sending

    func syncRecent(days: Int) {
        guard config.health.enabled, isPaired else { return }
        let list = (0..<days).map { Self.dayString(daysAgo: $0) }
        Task { await run(list) }
    }

    /// Each wake sends today. Once a day it also resends yesterday, because the Watch often syncs late.
    private func daysForWake() -> [String] {
        var days = [Self.dayString(daysAgo: 0)]
        let today = days[0]
        if defaults.string(forKey: "lw.yesterdayResentOn") != today {
            days.append(Self.dayString(daysAgo: 1))
            defaults.set(today, forKey: "lw.yesterdayResentOn")
        }
        return days
    }

    private func run(_ days: [String]) async {
        guard config.health.enabled, isPaired,
              let token = Keychain.get("token"),
              let urlString = Keychain.get("syncUrl"),
              let url = URL(string: urlString) else { return }

        let all = Array(Set(days + pending)).sorted()
        guard await gate.enter() else {
            // Another sync is running: queue these days for it.
            pending = pending + days
            return
        }
        DispatchQueue.main.async { self.isSyncing = true }

        var stillPending: [String] = []
        var sent = 0
        var errorText: String?
        var unauthorized = false

        for (index, day) in all.enumerated() {
            if Task.isCancelled || unauthorized {
                stillPending.append(contentsOf: all[index...])
                break
            }
            guard let summary = await summary(for: day) else {
                // Health data is locked (phone locked). Try again later.
                stillPending.append(day)
                continue
            }
            if summary.count <= 1 { continue } // Nothing recorded that day.
            switch await post(summary, to: url, token: token) {
            case .ok:
                sent += 1
            case .unauthorized:
                unauthorized = true
                stillPending.append(day)
            case .failed(let message):
                errorText = message
                stillPending.append(day)
            }
        }

        // Keep days that other syncs queued while this one ran.
        pending = stillPending + pending.filter { !all.contains($0) }
        if sent > 0 {
            let total = defaults.integer(forKey: "lw.daysSent") + sent
            let now = Date()
            defaults.set(total, forKey: "lw.daysSent")
            defaults.set(now, forKey: "lw.lastSync")
            DispatchQueue.main.async {
                self.daysSent = total
                self.lastSync = now
            }
        }
        if unauthorized { defaults.set(true, forKey: "lw.needsRepair") }
        let finalError = unauthorized ? "The sync code was reset. Pair again." : errorText
        DispatchQueue.main.async {
            self.isSyncing = false
            self.lastError = finalError
            if unauthorized { self.needsRepair = true }
        }
        await gate.leave()
    }

    private enum PostResult { case ok, unauthorized, failed(String) }

    private func post(_ body: [String: Any], to url: URL, token: String) async -> PostResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: config.tokenHeader)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .unauthorized }
            if (200..<300).contains(code) { return .ok }
            return .failed("The server answered \(code). Will try again.")
        } catch {
            return .failed("No connection to the server. Will try again.")
        }
    }

    // MARK: Day summary

    /// Returns nil when Health data can't be read right now (phone locked).
    private func summary(for day: String) async -> [String: Any]? {
        guard let start = Self.date(from: day),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [:] }
        var result: [String: Any] = ["date": day]
        for field in fields {
            let outcome: Outcome
            switch Self.catalog[field]! {
            case .sum(let id, let unit):
                outcome = await sum(id, unit, start, end)
            case .latest(let id, let unit, let factor):
                outcome = await latest(id, unit, start, end, factor)
            case .workouts:
                outcome = await workoutCount(start, end)
            }
            switch outcome {
            case .locked: return nil
            case .none: break
            case .value(let v):
                if ["weight", "bodyFat"].contains(field) {
                    result[field] = (v * 10).rounded() / 10
                } else {
                    result[field] = Int(v.rounded())
                }
            }
        }
        return result
    }

    private enum Outcome { case value(Double), none, locked }

    private func isLocked(_ error: Error?) -> Bool {
        guard let e = error as? HKError else { return false }
        return e.code == .errorDatabaseInaccessible
    }

    private func sum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date, _ end: Date) async -> Outcome {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return .none }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, error in
                if self.isLocked(error) { return cont.resume(returning: .locked) }
                if let v = stats?.sumQuantity()?.doubleValue(for: unit), v > 0 {
                    cont.resume(returning: .value(v))
                } else {
                    cont.resume(returning: .none)
                }
            }
            store.execute(q)
        }
    }

    private func latest(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date, _ end: Date, _ factor: Double) async -> Outcome {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return .none }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: sort) { _, samples, error in
                if self.isLocked(error) { return cont.resume(returning: .locked) }
                if let s = samples?.first as? HKQuantitySample {
                    cont.resume(returning: .value(s.quantity.doubleValue(for: unit) * factor))
                } else {
                    cont.resume(returning: .none)
                }
            }
            store.execute(q)
        }
    }

    private func workoutCount(_ start: Date, _ end: Date) async -> Outcome {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if self.isLocked(error) { return cont.resume(returning: .locked) }
                let n = samples?.count ?? 0
                cont.resume(returning: n > 0 ? .value(Double(n)) : .none)
            }
            store.execute(q)
        }
    }

    // MARK: Dates

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(daysAgo: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return formatter.string(from: d)
    }

    static func date(from day: String) -> Date? {
        guard let d = formatter.date(from: day) else { return nil }
        return Calendar.current.startOfDay(for: d)
    }
}

/// Makes sure only one sync runs at a time.
actor SyncGate {
    private var busy = false
    func enter() -> Bool {
        if busy { return false }
        busy = true
        return true
    }
    func leave() { busy = false }
}
