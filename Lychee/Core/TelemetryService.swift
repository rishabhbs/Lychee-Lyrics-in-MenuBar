import CryptoKit
import Foundation

/// Privacy-preserving product analytics. Event names and payload fields are
/// intentionally closed enums so track metadata cannot be sent accidentally.
final class TelemetryService {
    static let shared = TelemetryService()
    static let analyticsEnabledKey = "lychee.analytics.enabled"

    enum LyricsOutcome {
        case synced
        case plain
        case notFound
    }

    private enum Event: String {
        case installActivated = "Lychee.App.installActivated"
        case activeDay = "Lychee.App.activeDay"
        case firstLyricsSuccess = "Lychee.Lyrics.firstSuccess"
        case dailyLyricsSummary = "Lychee.Lyrics.dailySummary"
    }

    private enum Key {
        static let anonymousID = "lychee.telemetry.userID"
        static let providerVersion = "lychee.analytics.providerVersion"
        static let installEventQueued = "lychee.analytics.installEventQueued"
        static let firstSuccessQueued = "lychee.analytics.firstSuccessQueued"
        static let lastActiveDay = "lychee.analytics.lastActiveDay"
        static let summaryDay = "lychee.analytics.summaryDay"
        static let syncedCount = "lychee.analytics.syncedCount"
        static let plainCount = "lychee.analytics.plainCount"
        static let notFoundCount = "lychee.analytics.notFoundCount"
        static let latencyUnder2sCount = "lychee.analytics.latencyUnder2sCount"
        static let latency2To5sCount = "lychee.analytics.latency2To5sCount"
        static let latency5To10sCount = "lychee.analytics.latency5To10sCount"
        static let latencyOver10sCount = "lychee.analytics.latencyOver10sCount"
        static let pendingEvents = "lychee.analytics.pendingEvents"
    }

    private struct QueuedEvent: Codable {
        let id: String
        let type: String
        let payload: [String: String]
        let timestamp: Date?
    }

    // PostHog project tokens are write-only identifiers intended for client apps.
    private let projectToken = "phc_tfpgPSovaCMi24W3iu2t5YphuemhBwxRUsf3pNb4WLQi"
    private let endpoint = URL(string: "https://us.i.posthog.com/batch/")!
    private let providerVersion = "posthog-v1"
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "personal.dev.Lychee.telemetry", qos: .utility)
    private let session: URLSession
    private var isSending = false
    private var currentTask: URLSessionDataTask?

    var isEnabled: Bool {
        defaults.bool(forKey: Self.analyticsEnabledKey)
    }

    private init() {
        defaults.register(defaults: [Self.analyticsEnabledKey: true])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    /// Called once during app startup. Existing installations receive the
    /// activation event once after upgrading to this analytics implementation.
    func start() {
        queue.async { [weak self] in
            guard let self, self.shouldCollect else { return }
            self.migrateProviderIfNeeded()
            self.rollDailySummaryIfNeeded()
            if !self.defaults.bool(forKey: Key.installEventQueued) {
                self.defaults.set(true, forKey: Key.installEventQueued)
                self.enqueue(.installActivated)
            }
            self.flush()
        }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.analyticsEnabledKey)
        queue.async { [weak self] in
            guard let self else { return }
            if enabled {
                self.migrateProviderIfNeeded()
                self.rollDailySummaryIfNeeded()
                if !self.defaults.bool(forKey: Key.installEventQueued) {
                    self.defaults.set(true, forKey: Key.installEventQueued)
                    self.enqueue(.installActivated)
                }
                self.flush()
            } else {
                self.currentTask?.cancel()
                self.currentTask = nil
                self.isSending = false
                self.savePendingEvents([])
                self.clearDailyCounts()
            }
        }
    }

    /// Records real product use, rather than launches caused by Login Items.
    func recordActiveUse() {
        queue.async { [weak self] in
            guard let self, self.shouldCollect else { return }
            self.rollDailySummaryIfNeeded()
            self.enqueueActiveDayIfNeeded()
            self.flush()
        }
    }

    func recordLyricsOutcome(_ outcome: LyricsOutcome, latency: TimeInterval? = nil) {
        queue.async { [weak self] in
            guard let self, self.shouldCollect else { return }
            self.rollDailySummaryIfNeeded()
            self.enqueueActiveDayIfNeeded()

            switch outcome {
            case .synced:
                self.increment(Key.syncedCount)
                self.enqueueFirstSuccessIfNeeded()
            case .plain:
                self.increment(Key.plainCount)
                self.enqueueFirstSuccessIfNeeded()
            case .notFound:
                self.increment(Key.notFoundCount)
            }
            if let latency {
                self.incrementLatencyBucket(for: latency)
            }
            self.flush()
        }
    }

    func recordLyricsLatency(_ latency: TimeInterval) {
        queue.async { [weak self] in
            guard let self, self.shouldCollect else { return }
            self.rollDailySummaryIfNeeded()
            self.incrementLatencyBucket(for: latency)
            self.flush()
        }
    }

    private var shouldCollect: Bool {
        #if DEBUG
        return false
        #else
        return defaults.bool(forKey: Self.analyticsEnabledKey)
        #endif
    }

    private func enqueueActiveDayIfNeeded() {
        let day = Self.dayIdentifier(for: Date())
        guard defaults.string(forKey: Key.lastActiveDay) != day else { return }
        defaults.set(day, forKey: Key.lastActiveDay)
        enqueue(.activeDay)
    }

    private func enqueueFirstSuccessIfNeeded() {
        guard !defaults.bool(forKey: Key.firstSuccessQueued) else { return }
        defaults.set(true, forKey: Key.firstSuccessQueued)
        enqueue(.firstLyricsSuccess)
    }

    private func rollDailySummaryIfNeeded() {
        let today = Self.dayIdentifier(for: Date())
        guard let storedDay = defaults.string(forKey: Key.summaryDay) else {
            defaults.set(today, forKey: Key.summaryDay)
            return
        }
        guard storedDay != today else { return }

        let synced = defaults.integer(forKey: Key.syncedCount)
        let plain = defaults.integer(forKey: Key.plainCount)
        let notFound = defaults.integer(forKey: Key.notFoundCount)
        if synced + plain + notFound > 0 {
            enqueue(.dailyLyricsSummary, payload: [
                "synced": String(synced),
                "plain": String(plain),
                "notFound": String(notFound),
                "latencyUnder2s": String(defaults.integer(forKey: Key.latencyUnder2sCount)),
                "latency2To5s": String(defaults.integer(forKey: Key.latency2To5sCount)),
                "latency5To10s": String(defaults.integer(forKey: Key.latency5To10sCount)),
                "latencyOver10s": String(defaults.integer(forKey: Key.latencyOver10sCount))
            ])
        }
        clearDailyCounts()
        defaults.set(today, forKey: Key.summaryDay)
    }

    private func increment(_ key: String) {
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    private func incrementLatencyBucket(for latency: TimeInterval) {
        switch max(0, latency) {
        case ..<2:
            increment(Key.latencyUnder2sCount)
        case ..<5:
            increment(Key.latency2To5sCount)
        case ..<10:
            increment(Key.latency5To10sCount)
        default:
            increment(Key.latencyOver10sCount)
        }
    }

    private func clearDailyCounts() {
        defaults.set(0, forKey: Key.syncedCount)
        defaults.set(0, forKey: Key.plainCount)
        defaults.set(0, forKey: Key.notFoundCount)
        defaults.set(0, forKey: Key.latencyUnder2sCount)
        defaults.set(0, forKey: Key.latency2To5sCount)
        defaults.set(0, forKey: Key.latency5To10sCount)
        defaults.set(0, forKey: Key.latencyOver10sCount)
    }

    private func enqueue(_ event: Event, payload: [String: String] = [:]) {
        var enriched = payload
        let info = Bundle.main.infoDictionary
        enriched["appVersion"] = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        enriched["buildNumber"] = info?["CFBundleVersion"] as? String ?? "unknown"

        var pending = loadPendingEvents()
        pending.append(QueuedEvent(
            id: UUID().uuidString,
            type: event.rawValue,
            payload: enriched,
            timestamp: Date()
        ))
        savePendingEvents(Array(pending.suffix(64)))
    }

    private func migrateProviderIfNeeded() {
        guard defaults.string(forKey: Key.providerVersion) != providerVersion else { return }

        currentTask?.cancel()
        currentTask = nil
        isSending = false
        savePendingEvents([])
        defaults.removeObject(forKey: Key.installEventQueued)
        defaults.removeObject(forKey: Key.firstSuccessQueued)
        defaults.removeObject(forKey: Key.lastActiveDay)
        clearDailyCounts()
        defaults.set(Self.dayIdentifier(for: Date()), forKey: Key.summaryDay)
        defaults.set(providerVersion, forKey: Key.providerVersion)
    }

    private func flush() {
        guard shouldCollect, !isSending else { return }
        let events = loadPendingEvents()
        guard !events.isEmpty else { return }

        let bodies: [[String: Any]] = events.map { event in
            var properties: [String: Any] = [
                "distinct_id": anonymousClientID,
                "$process_person_profile": false,
                "$geoip_disable": true,
                "source": "macos_app",
                "is_test": false
            ]

            for (key, value) in event.payload {
                switch key {
                case "synced":
                    properties["synced_count"] = Int(value) ?? 0
                case "plain":
                    properties["plain_count"] = Int(value) ?? 0
                case "notFound":
                    properties["missing_count"] = Int(value) ?? 0
                case "latencyUnder2s":
                    properties["latency_under_2s_count"] = Int(value) ?? 0
                case "latency2To5s":
                    properties["latency_2_to_5s_count"] = Int(value) ?? 0
                case "latency5To10s":
                    properties["latency_5_to_10s_count"] = Int(value) ?? 0
                case "latencyOver10s":
                    properties["latency_over_10s_count"] = Int(value) ?? 0
                case "appVersion":
                    properties["app_version"] = value
                case "buildNumber":
                    properties["build_number"] = value
                default:
                    break
                }
            }

            var body: [String: Any] = [
                "event": event.type,
                "properties": properties
            ]
            if let timestamp = event.timestamp {
                body["timestamp"] = Self.iso8601Formatter.string(from: timestamp)
            }
            return body
        }
        let batch: [String: Any] = [
            "api_key": projectToken,
            "historical_migration": false,
            "batch": bodies
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: batch) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let sentIDs = Set(events.map(\.id))
        isSending = true
        currentTask = session.dataTask(with: request) { [weak self] _, response, _ in
            self?.queue.async {
                guard let self else { return }
                self.currentTask = nil
                self.isSending = false
                guard self.shouldCollect,
                      let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode) else { return }

                let remaining = self.loadPendingEvents().filter { !sentIDs.contains($0.id) }
                self.savePendingEvents(remaining)
                self.flush()
            }
        }
        currentTask?.resume()
    }

    private var anonymousClientID: String {
        let rawID: String
        if let existing = defaults.string(forKey: Key.anonymousID) {
            rawID = existing
        } else {
            rawID = UUID().uuidString
            defaults.set(rawID, forKey: Key.anonymousID)
        }
        return SHA256.hash(data: Data(rawID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func loadPendingEvents() -> [QueuedEvent] {
        guard let data = defaults.data(forKey: Key.pendingEvents),
              let events = try? JSONDecoder().decode([QueuedEvent].self, from: data) else {
            return []
        }
        return events
    }

    private func savePendingEvents(_ events: [QueuedEvent]) {
        if events.isEmpty {
            defaults.removeObject(forKey: Key.pendingEvents)
        } else if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: Key.pendingEvents)
        }
    }

    private static func dayIdentifier(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
