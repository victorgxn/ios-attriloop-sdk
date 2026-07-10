import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// Standard event types. `INSTALL` is emitted automatically by the backend on
/// first-open — never send it manually.
public enum AttriloopEvent: String {
    case login = "LOGIN"
    case signUp = "SIGN_UP"
    case register = "REGISTER"
    case purchase = "PURCHASE"
    case addToWishlist = "ADD_TO_WISHLIST"
    case initiateCheckout = "INITIATE_CHECKOUT"
    case startTrial = "START_TRIAL"
    case subscribe = "SUBSCRIBE"
    case levelStart = "LEVEL_START"
    case levelComplete = "LEVEL_COMPLETE"
    case tutorialComplete = "TUTORIAL_COMPLETE"
    case search = "SEARCH"
    case share = "SHARE"
    case custom = "CUSTOM"
}

/// Attriloop iOS SDK. Mirrors the documented Appstack SDK surface.
///
/// ```swift
/// Attriloop.shared.configure(apiKey: "at_live_...")
/// Attriloop.shared.sendEvent(.purchase, parameters: ["revenue": 29.99, "currency": "USD"])
/// Attriloop.shared.sendCustomEvent("share_referral", parameters: ["channel": "whatsapp"])
///
/// // Deferred attribution / creator params, resolved shortly after first-open:
/// Attriloop.shared.getAttributionParams { params in
///     // params["mediaSource"], params["campaignName"], params["linkId"]
/// }
/// ```
public final class Attriloop {
    public static let shared = Attriloop()

    // internal (not private): the Conversion extension lives in another file and needs
    // these to talk to the same endpoint with the same key.
    var apiKey = ""
    var baseURL = URL(string: "https://api.attriloop.com")!
    var isDebug = false
    let session = URLSession.shared
    private let sdkVersion = "ios/0.1.0"

    private let idKey = "com.attriloop.id"
    private let installedKey = "com.attriloop.installed"
    private let clickKey = "com.attriloop.clickId"
    private let deepLinkKey = "com.attriloop.deepLink" // last resolved deep_link_value
    private let attrKey = "com.attriloop.attribution"
    private let queueKey = "com.attriloop.queue" // persisted offline event buffer
    let convStateKey = "com.attriloop.convState" // persisted SKAN/AAK conversion state (fine+coarse)
    let convSchemaKey = "com.attriloop.convSchema" // cached server-defined conversion schema
    let skanRegisteredKey = "com.attriloop.skanRegistered" // registerAppForAdNetworkAttribution done

    /// Persistence backend for all on-disk state (id, queue, attribution cache,
    /// install flag). Injectable so unit tests can run against an isolated suite
    /// instead of the shared `.standard` domain. Defaults to `.standard`.
    var defaults: UserDefaults = .standard

    /// Max buffered events before the oldest are dropped (bounds disk + a runaway
    /// offline session). Drops are logged in debug.
    private let maxQueue = 500

    /// Serializes all access to the persisted event queue + `flushing` flag so the
    /// host app's `sendEvent` calls and the network-callback threads never race on
    /// UserDefaults.
    private let queueLock = DispatchQueue(label: "io.attriloop.queue")
    private var flushing = false

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Public install/device id — the attribution subject. Forward to partner SDKs
    /// (e.g. RevenueCat) via `getAttriloopId()`.
    public private(set) var attriloopId = ""

    /// Serializes all access to `attribution` / `handlers` / `polling` so the
    /// network-callback threads and host-app threads can't race.
    private let stateQueue = DispatchQueue(label: "io.attriloop.state")
    private var attribution: [String: Any] = [:]
    private var handlers: [([String: Any]) -> Void] = []
    private var polling = false
    // Deferred deep-link destination (`deep_link_value`) + its subscribers. Resolved
    // from a Universal Link (/v1/resolve) or the deferred attribution poll.
    private var deepLink: String?
    private var deepLinkHandlers: [(String) -> Void] = []
    // True only while `deepLink` holds a value resolved in THIS session (so it is
    // eligible to fire onDeepLink exactly once). A value restored from a previous
    // launch loads with this false: it feeds getDeepLink() but is treated as
    // already-consumed, so onDeepLink never re-broadcasts it on a cold launch.
    private var deepLinkIsFresh = false
    // Set the moment configure() runs on a first open; a Universal Link handled within
    // the short window below lets the one-shot install POST carry the click id.
    private var installDeadline = false

    private init() {}

    // MARK: - Lifecycle

    public func configure(apiKey: String, isDebug: Bool = false, endpointBaseURL: URL? = nil) {
        self.apiKey = apiKey
        self.isDebug = isDebug
        // Only accept an https override — an http:// base would send the Bearer SDK key
        // and every event body in cleartext (on any host that has disabled ATS). A
        // non-https override is ignored in favor of the secure default.
        if let endpointBaseURL {
            if endpointBaseURL.scheme?.lowercased() == "https" {
                self.baseURL = endpointBaseURL
            } else if isDebug {
                print("[Attriloop] endpointBaseURL must be https — ignoring \(endpointBaseURL), keeping \(baseURL).")
            }
        }
        self.attriloopId = loadOrCreateId(key: idKey)

        let saved = defaults.dictionary(forKey: attrKey)
        stateQueue.sync {
            if let saved { attribution = saved }
            // Load the last resolved deep link so getDeepLink() can still return it,
            // but mark it NOT fresh: it was resolved (and delivered) on a PREVIOUS
            // launch, so onDeepLink must not re-broadcast it and re-navigate the host
            // on this cold launch. Only a value resolved THIS session fires handlers.
            deepLink = defaults.string(forKey: deepLinkKey)
            deepLinkIsFresh = false
        }
        sendInstallIfFirstOpen()
        // Returning users (install already sent) still resolve attribution here;
        // a fresh install kicks the poll off only after the install POST succeeds.
        if defaults.bool(forKey: installedKey) { startPolling() }
        // Re-send any events buffered offline in a previous session.
        flushQueue()
        // Privacy-preserving Apple attribution (SKAdNetwork / AdAttributionKit): register
        // for ad-network attribution and refresh the server-defined conversion schema. No
        // ATT prompt and no IDFA are involved — this is Apple's consent-free channel.
        configureConversion()
    }

    // MARK: - Events

    /// Record an in-app event. The event is persisted to a durable on-disk queue
    /// FIRST, then a flush is attempted — so a transient network failure, timeout,
    /// or the app being backgrounded/killed mid-send never loses it. Pending events
    /// re-send on the next `sendEvent`, on the next `configure()`, and right after
    /// the install POST succeeds.
    public func sendEvent(_ event: AttriloopEvent, name: String? = nil, parameters: [String: Any]? = nil) {
        // A CUSTOM event with no name is rejected by the backend (422) and the offline
        // queue would then drop it as a permanent failure — silently losing it. Refuse
        // it here instead so the mistake is visible in debug. Use sendCustomEvent(_:).
        if Self.isDroppableCustom(event, name) {
            if isDebug { print("[Attriloop] .custom event requires a non-empty name — event dropped") }
            return
        }

        var item: [String: Any] = [
            "attriloopId": attriloopId,
            "appId": Bundle.main.bundleIdentifier ?? "",
            "event": event.rawValue,
            "eid": UUID().uuidString, // idempotency key — backend dedupes retries on this
            "eventTime": Self.iso8601.string(from: Date()),
        ]
        if let name { item["name"] = name }
        // Sanitize to JSON+plist-safe values: a raw [String: Any] can contain a
        // non-property-list value (e.g. Date) that CRASHES UserDefaults.set with an
        // uncatchable NSInvalidArgumentException, or a value that serializes to plist
        // but not JSON and then poison-blocks the queue at POST time.
        if let parameters { item["parameters"] = Self.validatedParams(parameters) }
        enqueue(item)
        flushQueue()
        // Fold this event into the SKAdNetwork / AdAttributionKit conversion value per
        // the server-defined schema. Monotonic + privacy-safe; no-op on unsupported OSes.
        applyConversion(for: event, name: name)
    }

    /// Record a CUSTOM event. `name` is the custom event label and is required —
    /// the backend rejects a nameless CUSTOM event.
    public func sendCustomEvent(_ name: String, parameters: [String: Any]? = nil) {
        sendEvent(.custom, name: name, parameters: parameters)
    }

    /// Result of a connectivity check. Inspect `success` and show `message` to the dev.
    public struct TestResult {
        public let success: Bool
        public let message: String
    }

    /// Synchronous connectivity check for setup. Unlike `sendEvent` (fire-and-forget
    /// through the offline queue), this awaits the HTTP response and returns a
    /// human-readable verdict — so during integration you can confirm the API key and
    /// endpoint are correct instead of shipping blind and discovering zero attribution
    /// later. Does NOT touch the offline queue.
    ///
    /// ```swift
    /// let r = await Attriloop.shared.sendTestEvent()
    /// print("\(r.success) — \(r.message)")
    /// ```
    public func sendTestEvent() async -> TestResult {
        guard !apiKey.isEmpty else {
            return TestResult(success: false, message: "Call configure(apiKey:) before sendTestEvent().")
        }
        guard let url = URL(string: "/v1/test", relativeTo: baseURL) else {
            return TestResult(success: false, message: "Invalid endpoint URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "attriloopId": attriloopId,
            "appId": Bundle.main.bundleIdentifier ?? "",
        ])
        // withCheckedContinuation (not URLSession.data(for:)) so this back-deploys to
        // the package's iOS 13 minimum; the async data API is iOS 15+.
        return await withCheckedContinuation { continuation in
            session.dataTask(with: req) { data, response, error in
                continuation.resume(
                    returning: Self.interpretTestResponse(data: data, response: response, error: error)
                )
            }.resume()
        }
    }

    /// Pure mapping from an HTTP outcome to a developer-facing verdict (unit-tested).
    static func interpretTestResponse(data: Data?, response: URLResponse?, error: Error?) -> TestResult {
        if let error {
            return TestResult(
                success: false,
                message: "Can't reach the edge — check the endpoint URL / that it's deployed. (\(error.localizedDescription))"
            )
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Prefer the server's own message when it sends one.
        let serverMessage = data
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["message"] as? String }
        switch code {
        case 200..<300:
            return TestResult(success: true, message: serverMessage ?? "SDK connected.")
        case 401:
            return TestResult(success: false, message: serverMessage ?? "Invalid API key (401).")
        case 403:
            return TestResult(success: false, message: serverMessage ?? "Wrong key type — use an SDK key (403).")
        case 429:
            return TestResult(success: false, message: "Rate limited (429) — try again in a moment.")
        default:
            return TestResult(success: false, message: serverMessage ?? "Edge reached but returned HTTP \(code).")
        }
    }

    /// A `.custom` event with no usable name can never be ingested (the backend
    /// requires a name for CUSTOM events). Pure predicate, exposed for tests.
    static func isDroppableCustom(_ event: AttriloopEvent, _ name: String?) -> Bool {
        event == .custom && (name?.isEmpty ?? true)
    }

    /// Keep only values that are safe for BOTH UserDefaults (property list) and JSON.
    /// Drops NSNull (not plist-valid); stringifies anything else non-serializable.
    static func jsonSanitized(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            if v is NSNull { continue }
            out[k] = JSONSerialization.isValidJSONObject([k: v]) ? v : String(describing: v)
        }
        return out
    }

    /// Recursively remove NSNull at any depth. A NESTED null (e.g. a server or caller
    /// value like `["creative": ["name": NSNull()]]`) is valid JSON but NOT a property
    /// list, so persisting it to UserDefaults throws an uncatchable
    /// NSInvalidArgumentException. jsonSanitized only strips the top level, so this is
    /// the durable guard for both event params and the cached attribution response.
    static func deepStripNSNull(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict where !(v is NSNull) {
                if let cleaned = deepStripNSNull(v) { out[k] = cleaned }
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.compactMap { deepStripNSNull($0) }
        }
        return value
    }

    /// Sanitize + VALIDATE event parameters so a malformed value degrades gracefully
    /// instead of 422-ing the whole event (which the offline queue then drops as a
    /// permanent failure — silently losing a revenue event). The backend enforces
    /// `revenue`/`price` = non-negative number and `currency` = 3 ASCII letters
    /// (see @attriloop/core EventParameters); we coerce/drop just those risky keys and
    /// pass everything else through. A bad `revenue` becomes an event with no revenue,
    /// never a lost purchase.
    static func validatedParams(_ dict: [String: Any]) -> [String: Any] {
        let stripped = (deepStripNSNull(dict) as? [String: Any]) ?? [:]
        var out = jsonSanitized(stripped)
        for key in ["revenue", "price"] where out[key] != nil {
            if let n = coerceNonNegNumber(out[key]) {
                out[key] = n
            } else {
                out.removeValue(forKey: key) // unparseable/negative → drop the key, keep the event
            }
        }
        if let currency = out["currency"] {
            let ok = (currency as? String)?.range(of: "^[A-Za-z]{3}$", options: .regularExpression) != nil
            if !ok { out.removeValue(forKey: "currency") }
        }
        return out
    }

    /// Coerce a value to a finite, non-negative Double, accepting Int/Double/NSNumber
    /// and numeric strings ("9.99"). Returns nil for anything else or a negative value.
    static func coerceNonNegNumber(_ value: Any?) -> Double? {
        // Bool bridges to NSNumber in Swift, so `true` would otherwise coerce to 1.0 —
        // a Bool is never a valid revenue/price, reject it before the NSNumber case.
        if value is Bool { return nil }
        let d: Double?
        switch value {
        case let n as Double: d = n
        case let i as Int: d = Double(i)
        case let s as String: d = Double(s)
        case let n as NSNumber: d = n.doubleValue
        default: d = nil
        }
        guard let d, d.isFinite, d >= 0 else { return nil }
        return d
    }

    /// Append to the persisted queue (capped — oldest dropped first).
    func enqueue(_ item: [String: Any]) {
        queueLock.sync {
            var q = defaults.array(forKey: queueKey) as? [[String: Any]] ?? []
            q.append(item)
            if q.count > maxQueue {
                let dropped = q.count - maxQueue
                q.removeFirst(dropped)
                if isDebug { print("[Attriloop] event queue full — dropped \(dropped) oldest") }
            }
            defaults.set(q, forKey: queueKey)
        }
    }

    /// Drain the persisted queue head-first. A delivered (2xx) OR permanently-rejected
    /// (4xx) head is removed; a transient failure (5xx / network / 408 / 429) stops the
    /// chain so the rest stay queued for a later flush. Single in-flight chain, guarded
    /// by `flushing`. Dropping permanent rejections is what prevents one bad event
    /// (e.g. a 422) from head-of-line-blocking the entire queue forever.
    public func flushQueue() {
        // Never flush before configure() sets a key: an empty `Bearer ` would 401 every
        // event. Events enqueued pre-configure stay durably queued and flush once
        // configure() runs (it calls flushQueue after setting apiKey). This is the guard
        // sendEvent lacks — a purchase fired before configure is preserved, not lost.
        guard !apiKey.isEmpty else { return }
        queueLock.sync {
            guard !flushing else { return }
            flushing = true
        }
        sendNextQueued()
    }

    private func sendNextQueued() {
        let head: [String: Any]? = queueLock.sync {
            (defaults.array(forKey: queueKey) as? [[String: Any]])?.first
        }
        guard let item = head else {
            queueLock.sync { flushing = false }
            return
        }
        let eid = item["eid"] as? String
        postOutcome(path: "/v1/event", body: item) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .ok:
                self.removeQueued(eid: eid)
                self.sendNextQueued()
            case .permanent:
                if self.isDebug { print("[Attriloop] dropping permanently-rejected event \(eid ?? "?")") }
                self.removeQueued(eid: eid)
                self.sendNextQueued()
            case .transient:
                self.queueLock.sync { self.flushing = false }
            }
        }
    }

    /// Remove the just-sent event BY eid, not by index 0: the lock is released across
    /// the in-flight POST, so a concurrent cap-eviction could shift indices and a blind
    /// removeFirst() would drop a different, never-sent event.
    func removeQueued(eid: String?) {
        queueLock.sync {
            var q = defaults.array(forKey: queueKey) as? [[String: Any]] ?? []
            if let eid {
                // Remove BY eid. If the eid is gone, the item was cap-evicted by a
                // concurrent enqueue while its POST was in flight — remove NOTHING. A
                // blind removeFirst() here would drop a different, never-sent event
                // (exactly the head-of-line hazard this method exists to avoid).
                guard let idx = q.firstIndex(where: { ($0["eid"] as? String) == eid }) else { return }
                q.remove(at: idx)
            } else if !q.isEmpty {
                q.removeFirst() // legacy items with no eid: fall back to head removal
            }
            defaults.set(q, forKey: queueKey)
        }
    }

    // MARK: - Attribution accessors

    public func getAttriloopId() -> String { attriloopId }

    /// Cached attribution params (`mediaSource`, `campaignName`, `linkId`,
    /// `matchMethod`, `confidence`, …). Empty until the backend resolves attribution
    /// shortly after first-open — prefer `getAttributionParams(_:)` to be called
    /// back the moment it resolves.
    public func getAttributionParams() -> [String: Any] { stateQueue.sync { attribution } }

    /// Async variant: invokes `completion` on the main queue with the resolved
    /// params (or the current cache if already resolved). Always fires — even if
    /// attribution never resolves it is eventually called with whatever is cached.
    public func getAttributionParams(_ completion: @escaping ([String: Any]) -> Void) {
        stateQueue.async {
            if !self.attribution.isEmpty {
                let resolved = self.attribution
                DispatchQueue.main.async { completion(resolved) }
            } else {
                self.handlers.append(completion)
                self.startPollingLocked()
            }
        }
    }

    /// Handle a deep link / Universal Link that launched or resumed the app.
    /// Call from `application(_:open:options:)`, scene URL handling, and the
    /// `NSUserActivity` (`continue userActivity:`) universal-link callback.
    ///
    /// Two shapes are accepted:
    ///  - a URL carrying an explicit `at_click` query token (custom-scheme redirect);
    ///  - a Universal Link `https://<host>/l/<token>/<slug>`, which is resolved via
    ///    `/v1/resolve` to fetch the click id + `deep_link_value` for that link.
    public func handleDeepLink(_ url: URL) {
        // Explicit at_click token on the URL (custom scheme).
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let click = comps.queryItems?.first(where: { $0.name == "at_click" })?.value,
           !click.isEmpty {
            defaults.set(click, forKey: clickKey)
            startPolling()
            return
        }
        // Namespaced Universal Link path /l/<token>/<slug>.
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 3, parts[0] == "l" {
            resolveDeepLink(slug: parts[2])
        }
    }

    /// Resolve a Universal Link's slug to its click id + deep-link value.
    private func resolveDeepLink(slug: String) {
        // Encode with a restricted set (NOT .urlQueryAllowed, which passes `& = + ?`
        // through) so a crafted Universal-Link slug can't inject extra query params into
        // /v1/resolve. Unreserved chars only — everything else is percent-escaped.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !apiKey.isEmpty,
              let encoded = slug.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return }
        get(path: "/v1/resolve?slug=\(encoded)") { [weak self] dict in
            guard let self, let dict else { return }
            if let click = dict["at_click"] as? String, !click.isEmpty {
                self.defaults.set(click, forKey: self.clickKey)
            }
            if let dlv = dict["deep_link_value"] as? String, !dlv.isEmpty {
                self.setDeepLink(dlv)
            }
            self.startPolling()
        }
    }

    /// Cache + broadcast a deep-link value resolved THIS session (from `/v1/resolve`)
    /// to `onDeepLink` subscribers. See broadcastDeepLinkLocked for the once-only rule.
    private func setDeepLink(_ value: String) {
        stateQueue.async { self.broadcastDeepLinkLocked(value) }
    }

    /// Must run on `stateQueue`. Deliver a deep-link value resolved THIS session to
    /// every `onDeepLink` subscriber. Marks it fresh so a subscriber that registers
    /// *after* resolution still gets it within the session, and persists it for
    /// getDeepLink() — but the fresh flag (cleared on the next launch by configure)
    /// is what guarantees the value is delivered once and never auto-re-broadcast on
    /// a later cold launch.
    private func broadcastDeepLinkLocked(_ value: String) {
        deepLink = value
        deepLinkIsFresh = true
        defaults.set(value, forKey: deepLinkKey) // kept for getDeepLink(), NOT for re-firing
        let pending = deepLinkHandlers
        DispatchQueue.main.async { pending.forEach { $0(value) } }
    }

    /// The last resolved deferred deep-link destination (`deep_link_value`), or nil.
    public func getDeepLink() -> String? { stateQueue.sync { deepLink } }

    /// Subscribe to deep-link resolutions. Fires on the main queue with the
    /// `deep_link_value` each time one resolves (Universal Link or deferred install).
    /// If a value already resolved THIS session it fires immediately with it; a value
    /// merely restored from a previous launch is treated as already-consumed and is
    /// NOT re-broadcast — otherwise the host would re-navigate to a stale destination
    /// on every cold launch. Net effect: each resolution is delivered exactly once.
    /// Treat the value as UNTRUSTED input when routing (it's a relative in-app route).
    public func onDeepLink(_ handler: @escaping (String) -> Void) {
        stateQueue.async {
            self.deepLinkHandlers.append(handler)
            if let dl = self.deepLink, self.deepLinkIsFresh {
                DispatchQueue.main.async { handler(dl) }
            }
        }
    }

    // MARK: - Install

    private func sendInstallIfFirstOpen() {
        guard !defaults.bool(forKey: installedKey) else { return }
        // If no click id has arrived yet, give a Universal Link a brief window to
        // resolve one (handleDeepLink → /v1/resolve) before sending the one-shot
        // install, so a deep-link launch attributes deterministically. Organic
        // launches wait this once; the install retry covers an early app kill.
        if defaults.string(forKey: clickKey) == nil && !installDeadline {
            installDeadline = true
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.sendInstallNow()
            }
            return
        }
        sendInstallNow()
    }

    private func sendInstallNow() {
        guard !defaults.bool(forKey: installedKey) else { return }

        var body: [String: Any] = [
            "attriloopId": attriloopId,
            "appId": Bundle.main.bundleIdentifier ?? "",
            "device": Self.deviceSignals(),
            "sdkVersion": sdkVersion,
            "installType": "new_install",
        ]
        if let click = defaults.string(forKey: clickKey) { body["clickId"] = click }
        // Apple Search Ads deterministic signal (iOS 14.3+). The backend verifies it
        // against Apple's API before crediting; an unattributed/old-OS token is simply
        // absent and falls through to fingerprint/organic.
        if let token = Self.adServicesToken() { body["adServicesToken"] = token }
        postInstall(body, attempt: 0)
    }

    /// POST /v1/install, marking the install done ONLY on a 2xx. On failure it
    /// retries with backoff and otherwise leaves the flag unset so the next launch
    /// re-attempts — the install is the root attribution event and must not be lost.
    private func postInstall(_ body: [String: Any], attempt: Int) {
        post(path: "/v1/install", body: body) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.defaults.set(true, forKey: self.installedKey)
                self.startPolling()
                self.flushQueue() // any events sent before the install landed
            } else if attempt < 3 {
                let delays: [Double] = [2, 5, 15]
                DispatchQueue.global().asyncAfter(deadline: .now() + delays[min(attempt, 2)]) {
                    self.postInstall(body, attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: - Apple Search Ads (AdServices)

    /// Apple Search Ads attribution token (iOS 14.3+), sent with the install so the
    /// backend can verify it against Apple's API and credit Apple Search Ads. Returns
    /// nil on older OSes or when AdServices is unavailable — harmless, the backend
    /// treats a missing/unverified token as a fall-through, not a credit.
    private static func adServicesToken() -> String? {
        #if canImport(AdServices)
        // macOS gate included so the package also compiles for a macOS host (SwiftPM
        // `swift test` builds for the host); the SDK itself ships iOS-only.
        if #available(iOS 14.3, macOS 11.1, *) {
            return try? AAAttribution.attributionToken()
        }
        #endif
        return nil
    }

    // MARK: - Attribution polling

    private func startPolling() { stateQueue.async { self.startPollingLocked() } }

    /// Must run on `stateQueue`. Starts a single poll chain; no-op if already
    /// resolved or a chain is in flight (avoids duplicate request storms).
    private func startPollingLocked() {
        guard attribution.isEmpty, !polling, !attriloopId.isEmpty else {
            if !attribution.isEmpty { flushHandlersLocked(attribution) }
            return
        }
        polling = true
        pollAttribution(attempt: 0)
    }

    private func pollAttribution(attempt: Int) {
        let delays: [Double] = [2, 4, 8, 16]
        let encoded = attriloopId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? attriloopId
        get(path: "/v1/attribution?attriloopId=\(encoded)") { [weak self] dict in
            guard let self else { return }
            // Deep-strip JSON nulls — `NSNull` (even nested) is not a property-list type
            // and would crash `UserDefaults.set` when the resolved attribution is cached.
            let clean = dict.flatMap { Self.deepStripNSNull($0) as? [String: Any] }
            if let clean, (clean["status"] as? String) != "pending", !clean.isEmpty {
                self.stateQueue.async { self.resolveLocked(clean) }
            } else if attempt < delays.count {
                DispatchQueue.global().asyncAfter(deadline: .now() + delays[attempt]) {
                    self.pollAttribution(attempt: attempt + 1)
                }
            } else {
                // Exhausted while still pending — release the poll lock and call any
                // waiters with whatever we have so completions never hang.
                self.stateQueue.async {
                    self.polling = false
                    self.flushHandlersLocked(self.attribution)
                }
            }
        }
    }

    /// Must run on `stateQueue`.
    private func resolveLocked(_ dict: [String: Any]) {
        attribution = dict
        defaults.set(dict, forKey: attrKey)
        polling = false
        // Deferred deep link: surface deep_link_value for navigation ONLY on a
        // trustworthy match (deterministic rung or high confidence) so a low-confidence
        // fingerprint guess doesn't misroute the user. Runs on stateQueue → set inline.
        if let dlv = dict["deep_link_value"] as? String, !dlv.isEmpty, deepLink != dlv {
            let method = dict["matchMethod"] as? String
            let deterministic = method == "deeplink" || method == "play_referrer"
            if deterministic || (dict["confidence"] as? String) == "high" {
                broadcastDeepLinkLocked(dlv)
            }
        }
        flushHandlersLocked(dict)
    }

    /// Must run on `stateQueue`.
    private func flushHandlersLocked(_ dict: [String: Any]) {
        guard !handlers.isEmpty else { return }
        let pending = handlers
        handlers = []
        DispatchQueue.main.async { pending.forEach { $0(dict) } }
    }

    // MARK: - Device signals

    private static func deviceSignals() -> [String: Any] {
        [
            "os": "ios",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "deviceModel": hardwareModel(),
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
        ]
    }

    /// Hardware identifier, e.g. "iPhone16,2" — read from `utsname` (no UIKit dep).
    private static func hardwareModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        return mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    // MARK: - Transport

    private func get(path: String, completion: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: path, relativeTo: baseURL) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: req) { data, response, error in
            if let error, self.isDebug { print("[Attriloop] GET \(path) failed: \(error)") }
            // Only a 2xx body is real data. Without this a 401/500 error body
            // (`{"error":"unauthorized"}`) has no `status` field, so the poll would
            // treat it as a RESOLVED attribution, cache the error dict forever, and
            // stop polling. Non-2xx → nil so the caller retries (or gives up cleanly).
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { completion(nil); return }
            completion(json)
        }.resume()
    }

    /// Delivery outcome: `ok` (2xx), `permanent` (4xx client error — never retry),
    /// `transient` (5xx / network / 408 / 429 — safe to retry later).
    enum SendOutcome: Equatable { case ok, permanent, transient }

    static func classify(code: Int, error: Error?) -> SendOutcome {
        if error != nil { return .transient }
        if (200..<300).contains(code) { return .ok }
        if code == 408 || code == 429 { return .transient } // timeout / rate-limited → retry
        // Auth failures are treated as TRANSIENT, not permanent: a 401/403 is usually a
        // recoverable operational condition (SDK key not yet provisioned when the app
        // shipped, a key mid-rotation, or an auth blip during an edge deploy), not a
        // malformed event. Dropping the queue on 401 would silently and permanently lose
        // buffered revenue/attribution events — the one thing this SDK promises not to do.
        // Left queued, they re-flush once the key is valid (mirrors the install path,
        // which also retries auth failures). The 500-item cap still bounds a genuinely
        // dead key, so there is no unbounded growth or retry storm.
        if code == 401 || code == 403 { return .transient }
        if (400..<500).contains(code) { return .permanent } // other 4xx → the server will keep rejecting
        return .transient // 5xx or unknown
    }

    private func postOutcome(path: String, body: [String: Any], completion: @escaping (SendOutcome) -> Void) {
        guard let url = URL(string: path, relativeTo: baseURL),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.permanent) // unserializable body will never succeed — drop it
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        session.dataTask(with: req) { _, response, error in
            if let error, self.isDebug { print("[Attriloop] \(path) failed: \(error)") }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(Self.classify(code: code, error: error))
        }.resume()
    }

    private func post(path: String, body: [String: Any], completion: ((Bool) -> Void)? = nil) {
        postOutcome(path: path, body: body) { completion?($0 == .ok) }
    }

    private func loadOrCreateId(key: String) -> String {
        if let existing = defaults.string(forKey: key) { return existing }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
}
