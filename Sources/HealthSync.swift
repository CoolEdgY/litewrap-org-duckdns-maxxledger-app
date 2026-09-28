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
    @Published private(set) var healthAsked: Bool?
    @Published private(set) var lastServerAnswer: String?
    @Published private(set) var lastSent: String?
    @Published private(set) var workoutsAnswer: String?
    @Published private(set) var historyStatus: String?

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

    private var workoutsEnabled: Bool { fields.contains("workouts") }

    /// Everything the app asks to read. Workout details need heart rate, energy and distance too.
    private var readTypes: Set<HKObjectType> {
        var set = Set(sampleTypes.map { $0 as HKObjectType })
        if workoutsEnabled {
            set.insert(HKObjectType.workoutType())
            for id in [HKQuantityTypeIdentifier.heartRate, .activeEnergyBurned, .distanceWalkingRunning,
                       .distanceCycling, .distanceSwimming] {
                if let t = HKQuantityType.quantityType(forIdentifier: id) { set.insert(t) }
            }
        }
        return set
    }

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
        lastServerAnswer = defaults.string(forKey: "lw.lastServerAnswer")
        lastSent = defaults.string(forKey: "lw.lastSent")
        workoutsAnswer = defaults.string(forKey: "lw.workoutsAnswer")
        historyStatus = defaults.string(forKey: "lw.historyStatus")
        refreshAuthStatus()
    }

    /// Whether iOS already showed the Health permission sheet. (iOS never tells apps which read types were allowed.)
    func refreshAuthStatus() {
        guard config.health.enabled, HKHealthStore.isHealthDataAvailable() else { return }
        let read = readTypes
        store.getRequestStatusForAuthorization(toShare: [], read: read) { status, _ in
            DispatchQueue.main.async { self.healthAsked = (status == .unnecessary) }
        }
    }

    /// Shows Apple's Health sheet only if there are types not asked for yet (for example after an update).
    func ensureAuthorization(_ done: @escaping () -> Void) {
        guard config.health.enabled, isPaired, HKHealthStore.isHealthDataAvailable() else { return done() }
        store.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, _ in
            if status == .shouldRequest { self.requestAuthorization(done) } else { done() }
        }
    }

    func askHealthAccess() {
        requestAuthorization {
            self.refreshAuthStatus()
            self.startObserving()
            self.syncRecent(days: 7)
        }
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
        defaults.set(false, forKey: "lw.workoutsBackfilled")
        defaults.set(false, forKey: "lw.daysBackfilled")
        defaults.removeObject(forKey: "lw.backfillCursor")
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
        observing = false
        pending = []
        DispatchQueue.main.async { self.isPaired = false }
    }

    private func requestAuthorization(_ done: @escaping () -> Void) {
        guard config.health.enabled, HKHealthStore.isHealthDataAvailable() else { return done() }
        let read = readTypes
        store.requestAuthorization(toShare: nil, read: read) { _, _ in
            self.refreshAuthStatus()
            done()
        }
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
        ensureAuthorization { self.syncRecentNow(days: days) }
    }

    private func syncRecentNow(days: Int) {
        let list = (0..<days).map { Self.dayString(daysAgo: $0) }
        Task { await run(list, backfill: true) }
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

    /// backfill: also send history. Only when the app is open; background wakes are too short for it.
    private func run(_ days: [String], backfill: Bool = false) async {
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
        var anyData = false

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
            anyData = true
            switch await post(summary, to: url, token: token) {
            case .ok:
                sent += 1
                let text = summary.keys.sorted().map { "\($0) \(summary[$0]!)" }.joined(separator: ", ")
                defaults.set(text, forKey: "lw.lastSent")
                DispatchQueue.main.async { self.lastSent = text }
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
        if sent > 0 && !unauthorized {
            defaults.set(false, forKey: "lw.needsRepair")
            DispatchQueue.main.async { self.needsRepair = false }
        }
        var finalError = unauthorized ? "The server refused the sync code (401). Pair again, or update the app if this keeps happening." : errorText
        if finalError == nil && !anyData && stillPending.isEmpty {
            finalError = "No Health data found for these days. Check Settings > Health > Data Access & Devices > \(config.name) and turn all categories on."
        }
        DispatchQueue.main.async {
            self.lastError = finalError
            if unauthorized { self.needsRepair = true }
        }
        if backfill && !unauthorized && !defaults.bool(forKey: "lw.daysBackfilled") {
            await backfillDays(token: token, url: url)
        }
        if workoutsEnabled && !unauthorized {
            await syncWorkouts(token: token, syncURL: url)
        }
        DispatchQueue.main.async { self.isSyncing = false }
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
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data.prefix(160), encoding: .utf8) ?? ""
            let answer = "\(code) \(body)"
            defaults.set(answer, forKey: "lw.lastServerAnswer")
            DispatchQueue.main.async { self.lastServerAnswer = answer }
            if code == 401 || code == 403 { return .unauthorized }
            if (200..<300).contains(code) { return .ok }
            return .failed("The server answered \(code). Will try again.")
        } catch {
            let answer = "No connection: \(error.localizedDescription)"
            defaults.set(answer, forKey: "lw.lastServerAnswer")
            DispatchQueue.main.async { self.lastServerAnswer = answer }
            return .failed("No connection to the server. Will try again.")
        }
    }

    // MARK: History (daily summaries, up to 2 years back)

    /// "Sync all history" button: send every day again, then keep going as normal.
    func syncAllHistory() {
        defaults.set(false, forKey: "lw.daysBackfilled")
        defaults.removeObject(forKey: "lw.backfillCursor")
        defaults.set(false, forKey: "lw.workoutsBackfilled")
        setHistory("History: starting...")
        syncRecent(days: 7)
    }

    private func setHistory(_ text: String) {
        defaults.set(text, forKey: "lw.historyStatus")
        DispatchQueue.main.async { self.historyStatus = text }
    }

    /// Sends one summary per day for every day Apple Health has data, oldest first, one at a time.
    /// Remembers how far it got, so a background wake that runs out of time continues next time.
    private func backfillDays(token: String, url: URL) async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .year, value: -2, to: today),
              let end = cal.date(byAdding: .day, value: 1, to: today) else { return }
        setHistory("History: reading Apple Health...")
        guard let all = await historySummaries(from: start, to: end) else {
            setHistory("History: Health data locked (phone locked). Will continue later.")
            return
        }
        let cursor = defaults.string(forKey: "lw.backfillCursor") ?? ""
        let days = all.keys.sorted()
        let todo = days.filter { $0 > cursor }
        var sent = days.count - todo.count
        for day in todo {
            if Task.isCancelled { return }
            var body = all[day]!
            body["date"] = day
            switch await post(body, to: url, token: token) {
            case .ok:
                sent += 1
                defaults.set(day, forKey: "lw.backfillCursor")
                if sent % 10 == 0 || sent == days.count {
                    setHistory("History: \(sent) of \(days.count) days sent")
                }
            case .unauthorized:
                setHistory("History: the server refused the sync code. Pair again.")
                defaults.set(true, forKey: "lw.needsRepair")
                DispatchQueue.main.async { self.needsRepair = true }
                return
            case .failed(let msg):
                setHistory("History: \(sent) of \(days.count) days sent. Stopped: \(msg)")
                return
            }
        }
        defaults.set(true, forKey: "lw.daysBackfilled")
        setHistory("History: done, \(days.count) days sent")
    }

    /// All day summaries between two dates, built with a few bulk queries instead of one per day.
    /// Returns nil when Health data can't be read (phone locked).
    private func historySummaries(from start: Date, to end: Date) async -> [String: [String: Any]]? {
        var out: [String: [String: Any]] = [:]
        for field in fields {
            let result: [String: Double]?
            switch Self.catalog[field]! {
            case .sum(let id, let unit):
                result = await dailySums(id, unit, start, end)
            case .latest(let id, let unit, let factor):
                result = await dailyLatest(id, unit, factor, start, end)
            case .workouts:
                result = await dailyWorkoutCounts(start, end)
            }
            guard let values = result else { return nil }
            for (day, v) in values {
                var d = out[day] ?? [:]
                if ["weight", "bodyFat"].contains(field) {
                    d[field] = (v * 10).rounded() / 10
                } else {
                    d[field] = Int(v.rounded())
                }
                out[day] = d
            }
        }
        return out
    }

    private func dailySums(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date, _ end: Date) async -> [String: Double]? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: .cumulativeSum, anchorDate: start,
                                                intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, error in
                if self.isLocked(error) { return cont.resume(returning: nil) }
                var values: [String: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    if let v = stats.sumQuantity()?.doubleValue(for: unit), v > 0 {
                        values[Self.formatter.string(from: stats.startDate)] = v
                    }
                }
                cont.resume(returning: values)
            }
            store.execute(q)
        }
    }

    private func dailyLatest(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ factor: Double, _ start: Date, _ end: Date) async -> [String: Double]? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, error in
                if self.isLocked(error) { return cont.resume(returning: nil) }
                var values: [String: Double] = [:]
                for case let s as HKQuantitySample in samples ?? [] {
                    values[Self.formatter.string(from: s.startDate)] = s.quantity.doubleValue(for: unit) * factor  // later samples win
                }
                cont.resume(returning: values)
            }
            store.execute(q)
        }
    }

    private func dailyWorkoutCounts(_ start: Date, _ end: Date) async -> [String: Double]? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if self.isLocked(error) { return cont.resume(returning: nil) }
                var values: [String: Double] = [:]
                for s in samples ?? [] {
                    values[Self.formatter.string(from: s.startDate), default: 0] += 1
                }
                cont.resume(returning: values)
            }
            store.execute(q)
        }
    }

    // MARK: Workouts

    /// Where workouts go: "workoutsPath" from litewrap.json, else the sync address with /sync replaced by /workouts.
    private func workoutsURL(from syncURL: URL) -> URL? {
        if let path = config.health.workoutsPath, !path.isEmpty {
            return URL(string: path, relativeTo: syncURL)?.absoluteURL
        }
        // Replace the last "sync" part of the path with "workouts", ignoring any query or trailing slash.
        guard var parts = URLComponents(url: syncURL, resolvingAgainstBaseURL: false) else { return nil }
        var segs = parts.path.split(separator: "/").map(String.init)
        guard let i = segs.lastIndex(where: { $0.lowercased() == "sync" }) else { return nil }
        segs[i] = "workouts"
        parts.path = "/" + segs.joined(separator: "/")
        parts.query = nil
        return parts.url
    }

    /// First time after pairing: every workout in Apple Health. After that: the last 7 days on every sync.
    private func syncWorkouts(token: String, syncURL: URL) async {
        guard let url = workoutsURL(from: syncURL) else {
            let msg = "Workouts: can't work out the address from \(syncURL.absoluteString). Add workoutsPath to litewrap.json."
            defaults.set(msg, forKey: "lw.workoutsAnswer")
            DispatchQueue.main.async { self.workoutsAnswer = msg }
            return
        }
        let backfilled = defaults.bool(forKey: "lw.workoutsBackfilled")
        let start = backfilled
            ? (Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date())) ?? Date())
            : Date.distantPast
        guard let workouts = await fetchWorkouts(since: start) else {
            let msg = "Workouts: Health data locked (phone locked). Will try again."
            defaults.set(msg, forKey: "lw.workoutsAnswer")
            DispatchQueue.main.async { self.workoutsAnswer = msg }
            return
        }
        var allOK = true
        var answer = ""
        var index = 0
        // Always call the server, also with an empty list, so it can see the phone checked.
        repeat {
            let batch = Array(workouts[index..<min(index + 500, workouts.count)])
            index += 500
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token, forHTTPHeaderField: config.tokenHeader)
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["workouts": batch])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    answer = (json?["message"] as? String) ?? "Sent \(workouts.count) workouts"
                    if workouts.isEmpty {
                        answer = "Apple Health returned 0 workouts to the app. Server called anyway."
                    }
                } else {
                    allOK = false
                    answer = "Workouts: \(url.absoluteString) answered \(code)"
                    break
                }
            } catch {
                allOK = false
                answer = "Workouts: no connection, will try again"
                break
            }
        } while index < workouts.count
        if allOK && !backfilled && !workouts.isEmpty { defaults.set(true, forKey: "lw.workoutsBackfilled") }
        defaults.set(answer, forKey: "lw.workoutsAnswer")
        DispatchQueue.main.async { self.workoutsAnswer = answer }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    /// Returns nil when Health data can't be read (phone locked).
    private func fetchWorkouts(since start: Date) async -> [[String: Any]]? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples: [HKWorkout]? = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, error in
                if self.isLocked(error) { return cont.resume(returning: nil) }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        guard let samples else { return nil }
        return samples.map { w in
            var d: [String: Any] = [
                "id": w.uuid.uuidString,
                "type": Self.activityName(w.workoutActivityType),
                "day": Self.formatter.string(from: w.startDate),
                "start": Self.isoFormatter.string(from: w.startDate),
                "end": Self.isoFormatter.string(from: w.endDate),
                "minutes": (w.duration / 60 * 10).rounded() / 10
            ]
            if let indoor = w.metadata?[HKMetadataKeyIndoorWorkout] as? NSNumber {
                d["indoor"] = indoor.boolValue
            }
            if let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()), kcal > 0 {
                d["kcal"] = Int(kcal.rounded())
            }
            var meters = 0.0
            for id in [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling, .distanceSwimming] {
                meters += w.statistics(for: HKQuantityType(id))?.sumQuantity()?.doubleValue(for: .meter()) ?? 0
            }
            if meters > 0 { d["km"] = (meters / 10).rounded() / 100 }
            if let hr = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())), hr > 0 {
                d["hr"] = Int(hr.rounded())
            }
            return d
        }
    }

    static func activityName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .traditionalStrengthTraining: return "traditionalStrengthTraining"
        case .functionalStrengthTraining: return "functionalStrengthTraining"
        case .highIntensityIntervalTraining: return "highIntensityIntervalTraining"
        case .swimming: return "swimming"
        case .yoga: return "yoga"
        case .hiking: return "hiking"
        case .rowing: return "rowing"
        case .elliptical: return "elliptical"
        case .coreTraining: return "coreTraining"
        case .crossTraining: return "crossTraining"
        case .mixedCardio: return "mixedCardio"
        case .stairClimbing: return "stairClimbing"
        case .stairs: return "stairs"
        case .stepTraining: return "stepTraining"
        case .pilates: return "pilates"
        case .flexibility: return "flexibility"
        case .cooldown: return "cooldown"
        case .dance, .cardioDance: return "dance"
        case .socialDance: return "socialDance"
        case .boxing: return "boxing"
        case .kickboxing: return "kickboxing"
        case .martialArts: return "martialArts"
        case .jumpRope: return "jumpRope"
        case .soccer: return "soccer"
        case .basketball: return "basketball"
        case .tennis: return "tennis"
        case .badminton: return "badminton"
        case .tableTennis: return "tableTennis"
        case .pickleball: return "pickleball"
        case .squash: return "squash"
        case .golf: return "golf"
        case .climbing: return "climbing"
        case .crossCountrySkiing: return "crossCountrySkiing"
        case .downhillSkiing: return "downhillSkiing"
        case .snowboarding: return "snowboarding"
        case .paddleSports: return "paddleSports"
        case .mindAndBody: return "mindAndBody"
        case .preparationAndRecovery: return "preparationAndRecovery"
        case .taiChi: return "taiChi"
        case .barre: return "barre"
        default: return "other"
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
