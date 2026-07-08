import Foundation
// SKAdNetwork is iOS-only (absent on the macOS host that `swift test` builds for), so
// gate on `os(iOS)` rather than `canImport(StoreKit)` — StoreKit imports on macOS but
// SKAdNetwork does not exist there. AdAttributionKit is a distinct iOS-only framework,
// so `canImport` cleanly excludes it on the host.
#if os(iOS)
import StoreKit
#endif
#if canImport(AdAttributionKit)
import AdAttributionKit
#endif

// Privacy-preserving Apple attribution: SKAdNetwork (iOS 14+) and AdAttributionKit
// (iOS 17.4+).
//
// WHY (the legal channel): after ATT, an install driven by a paid ad network can only
// be measured through Apple's sanctioned, aggregated, consent-free path. We report a
// *conversion value* on-device; Apple sends a cryptographically-signed postback (with
// NO user/device identifier) to the ad network and to our developer-copy endpoint.
// None of this uses the IDFA or requires an ATT prompt — it is GDPR/CCPA-safe by
// construction, so it runs unconditionally.
//
// HOW it stays flexible (scalable): the mapping from in-app event → conversion value
// is DEFINED ON THE SERVER (`/v1/skan-config`) and fetched at launch, so a customer
// can retune what a value means without shipping a new build.

extension Attriloop {
    /// Server-defined conversion schema, mirroring `@attriloop/core`'s `ConversionSchema`.
    struct ConversionSchema: Codable {
        struct Rule: Codable {
            let event: String
            let fine: Int
            let coarse: String // "low" | "medium" | "high"
            let lockWindow: Bool
            let priority: Int
        }
        let version: Int
        let rules: [Rule]
        let installCoarse: String
    }

    /// Per-install conversion state, persisted so updates are monotonic across launches.
    struct ConversionState: Equatable {
        var fine: Int
        var coarse: String
    }

    /// Serializes conversion-state read-modify-write so concurrent `sendEvent` calls
    /// can't race on the persisted value. Static: extensions can't add stored props.
    private static let convQueue = DispatchQueue(label: "io.attriloop.conversion")

    private static let coarseRank: [String: Int] = ["low": 0, "medium": 1, "high": 2]

    // MARK: - Pure fold (unit-tested, mirrors core `foldConversion`)

    /// Fold a fired event into the conversion state honoring Apple's rule that a
    /// conversion value may only INCREASE within a window (a decreasing update is
    /// dropped by the OS). Highest-priority matching rule wins. Returns the new state
    /// and whether the postback window should be locked (only when the value advanced).
    static func foldConversion(
        _ schema: ConversionSchema,
        _ state: ConversionState,
        event: String
    ) -> (state: ConversionState, lockWindow: Bool) {
        let rule = schema.rules
            .filter { $0.event == event }
            .max { $0.priority < $1.priority }
        guard let rule else { return (state, false) }

        // Clamp to SKAdNetwork's valid 0...63 range. A server schema rule with fine > 63
        // (dashboard misconfig or schema-version drift) would otherwise be persisted by
        // the monotonic max and then REJECTED by every updatePostbackConversionValue call
        // — silently killing that install's conversion reporting for good. Clamping keeps
        // the value reportable instead of poisoning the state.
        let nextFine = min(63, max(0, max(state.fine, rule.fine)))
        let ruleRank = coarseRank[rule.coarse] ?? 0
        let stateRank = coarseRank[state.coarse] ?? 0
        let nextCoarse = ruleRank >= stateRank ? rule.coarse : state.coarse

        let changed = nextFine != state.fine || nextCoarse != state.coarse
        return (ConversionState(fine: nextFine, coarse: nextCoarse), changed && rule.lockWindow)
    }

    // MARK: - Lifecycle

    /// Register for ad-network attribution (once) and refresh the conversion schema.
    /// Reporting the baseline install value makes an install measurable even with zero
    /// in-app activity.
    func configureConversion() {
        registerForAdNetworkAttribution()
        fetchConversionSchema { [weak self] schema in
            guard let self, let schema else { return }
            // Baseline: ensure the install itself produces a postback at the schema's
            // install coarse value (monotonic — never lowers an already-advanced value).
            Self.convQueue.async {
                let current = self.loadConversionState()
                let baseline = ConversionState(fine: current.fine, coarse: self.raiseCoarse(current.coarse, to: schema.installCoarse))
                if baseline != current {
                    self.saveConversionState(baseline)
                    self.reportConversion(fine: baseline.fine, coarse: baseline.coarse, lock: false)
                }
            }
        }
    }

    /// Fold the event into the conversion value and report it to both frameworks.
    func applyConversion(for event: AttriloopEvent, name: String?) {
        let key = event == .custom ? (name ?? "") : event.rawValue
        guard !key.isEmpty else { return }
        Self.convQueue.async {
            guard let schema = self.loadConversionSchema() else { return }
            let current = self.loadConversionState()
            let result = Self.foldConversion(schema, current, event: key)
            guard result.state != current else { return } // monotonic no-op → skip the OS call
            self.saveConversionState(result.state)
            self.reportConversion(fine: result.state.fine, coarse: result.state.coarse, lock: result.lockWindow)
        }
    }

    // MARK: - OS reporting (availability-gated, no IDFA / no ATT)

    private func registerForAdNetworkAttribution() {
        guard !defaults.bool(forKey: skanRegisteredKey) else { return }
        #if os(iOS)
        if #available(iOS 14.0, *) {
            // On iOS 15.4+ the first updatePostbackConversionValue implicitly registers,
            // but calling this is harmless and covers iOS 14.0–15.3.
            SKAdNetwork.registerAppForAdNetworkAttribution()
        }
        #endif
        defaults.set(true, forKey: skanRegisteredKey)
    }

    /// Report a conversion value to SKAdNetwork and (on 17.4+) AdAttributionKit, using
    /// the newest API available on the running OS.
    private func reportConversion(fine: Int, coarse: String, lock: Bool) {
        #if os(iOS)
        if #available(iOS 16.1, *) {
            let coarseValue = Self.skanCoarse(coarse)
            SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: coarseValue, lockWindow: lock) { error in
                if let error, self.isDebug { print("[Attriloop] SKAN postback update failed: \(error)") }
            }
        } else if #available(iOS 15.4, *) {
            SKAdNetwork.updatePostbackConversionValue(fine) { error in
                if let error, self.isDebug { print("[Attriloop] SKAN conversion update failed: \(error)") }
            }
        } else if #available(iOS 14.0, *) {
            // Legacy pre-15.4 API (no coarse value / lock support).
            SKAdNetwork.updateConversionValue(fine)
        }
        #endif

        #if canImport(AdAttributionKit)
        if #available(iOS 17.4, *) {
            Task {
                do {
                    try await Postback.updateConversionValue(
                        fine,
                        coarseConversionValue: Self.aakCoarse(coarse),
                        lockPostback: lock
                    )
                } catch {
                    if self.isDebug { print("[Attriloop] AdAttributionKit postback update failed: \(error)") }
                }
            }
        }
        #endif
    }

    #if os(iOS)
    @available(iOS 16.1, *)
    private static func skanCoarse(_ s: String) -> SKAdNetwork.CoarseConversionValue {
        switch s {
        case "high": return .high
        case "medium": return .medium
        default: return .low
        }
    }
    #endif

    #if canImport(AdAttributionKit)
    @available(iOS 17.4, *)
    private static func aakCoarse(_ s: String) -> CoarseConversionValue {
        switch s {
        case "high": return .high
        case "medium": return .medium
        default: return .low
        }
    }
    #endif

    // MARK: - State persistence + schema fetch

    private func raiseCoarse(_ current: String, to target: String) -> String {
        (Self.coarseRank[target] ?? 0) > (Self.coarseRank[current] ?? 0) ? target : current
    }

    func loadConversionState() -> ConversionState {
        let d = defaults.dictionary(forKey: convStateKey)
        return ConversionState(
            fine: d?["fine"] as? Int ?? 0,
            coarse: d?["coarse"] as? String ?? "low"
        )
    }

    private func saveConversionState(_ s: ConversionState) {
        defaults.set(["fine": s.fine, "coarse": s.coarse], forKey: convStateKey)
    }

    func loadConversionSchema() -> ConversionSchema? {
        guard let data = defaults.data(forKey: convSchemaKey) else { return nil }
        return try? JSONDecoder().decode(ConversionSchema.self, from: data)
    }

    private func fetchConversionSchema(_ completion: @escaping (ConversionSchema?) -> Void) {
        guard let url = URL(string: "/v1/skan-config", relativeTo: baseURL) else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { completion(nil); return }
            if let error, self.isDebug { print("[Attriloop] skan-config fetch failed: \(error)") }
            // Only a 2xx body is a real schema. Guard the status the same way get() does
            // so a non-2xx response (or a 2xx-shaped non-schema) is never cached — fall
            // through to the last good cached schema instead.
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), let data,
                  let schema = try? JSONDecoder().decode(ConversionSchema.self, from: data) else {
                // Keep any previously-cached schema on a fetch/parse/non-2xx failure.
                completion(self.loadConversionSchema()); return
            }
            self.defaults.set(data, forKey: self.convSchemaKey)
            completion(schema)
        }.resume()
    }
}
