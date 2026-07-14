import XCTest
@testable import AttriloopSDK

final class AttriloopSDKTests: XCTestCase {
    // Isolated UserDefaults suite so tests never touch the real `.standard` domain.
    private let suiteName = "io.attriloop.tests"
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        Attriloop.shared.defaults = suite
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        Attriloop.shared.defaults = .standard
        super.tearDown()
    }

    // MARK: - CUSTOM guard (A1)

    func testCustomWithoutNameIsDroppable() {
        XCTAssertTrue(Attriloop.isDroppableCustom(.custom, nil))
        XCTAssertTrue(Attriloop.isDroppableCustom(.custom, ""))
    }

    func testCustomWithNameIsNotDroppable() {
        XCTAssertFalse(Attriloop.isDroppableCustom(.custom, "share_referral"))
    }

    func testNonCustomEventsAreNeverDroppable() {
        XCTAssertFalse(Attriloop.isDroppableCustom(.purchase, nil))
        XCTAssertFalse(Attriloop.isDroppableCustom(.login, ""))
    }

    // MARK: - Universal-Link slug parsing

    func testUniversalLinkSlugSharedHostShape() {
        let url = URL(string: "https://go.attriloop.com/l/tok123/mySlug")!
        XCTAssertEqual(Attriloop.universalLinkSlug(url), "mySlug")
    }

    func testUniversalLinkSlugBrandedDomainShape() {
        let url = URL(string: "https://go.faithlocked.com/l/ns3BaBvT")!
        XCTAssertEqual(Attriloop.universalLinkSlug(url), "ns3BaBvT")
    }

    func testUniversalLinkSlugRejectsNonLinkPaths() {
        XCTAssertNil(Attriloop.universalLinkSlug(URL(string: "https://go.attriloop.com/l")!))
        XCTAssertNil(Attriloop.universalLinkSlug(URL(string: "https://go.attriloop.com/")!))
        XCTAssertNil(Attriloop.universalLinkSlug(URL(string: "https://go.attriloop.com/x/tok/slug")!))
    }

    // MARK: - jsonSanitized

    func testJsonSanitizedDropsNSNull() {
        let out = Attriloop.jsonSanitized(["a": 1, "b": NSNull()])
        XCTAssertEqual(out["a"] as? Int, 1)
        XCTAssertNil(out["b"])
    }

    func testJsonSanitizedStringifiesNonSerializable() {
        let out = Attriloop.jsonSanitized([
            "d": Date(timeIntervalSince1970: 0),
            "s": "ok",
            "n": 3.5,
        ])
        XCTAssertEqual(out["s"] as? String, "ok")
        XCTAssertEqual(out["n"] as? Double, 3.5)
        XCTAssertNotNil(out["d"] as? String) // Date is not JSON-valid → String(describing:)
    }

    // MARK: - classify (outcome mapping)

    func testClassifyOk() {
        XCTAssertEqual(Attriloop.classify(code: 200, error: nil), .ok)
        XCTAssertEqual(Attriloop.classify(code: 204, error: nil), .ok)
    }

    func testClassifyPermanentOn4xx() {
        XCTAssertEqual(Attriloop.classify(code: 400, error: nil), .permanent)
        XCTAssertEqual(Attriloop.classify(code: 422, error: nil), .permanent)
    }

    func testClassifyTransientOnRetryableCodes() {
        XCTAssertEqual(Attriloop.classify(code: 408, error: nil), .transient)
        XCTAssertEqual(Attriloop.classify(code: 429, error: nil), .transient)
        XCTAssertEqual(Attriloop.classify(code: 500, error: nil), .transient)
        XCTAssertEqual(Attriloop.classify(code: 503, error: nil), .transient)
    }

    func testClassifyAuthFailuresAreTransientNotPermanent() {
        // 401/403 must NOT drain the durable queue — a provisioning/rotation blip should
        // leave events queued to re-flush once the key is valid, not drop revenue events.
        XCTAssertEqual(Attriloop.classify(code: 401, error: nil), .transient)
        XCTAssertEqual(Attriloop.classify(code: 403, error: nil), .transient)
        // Genuine client errors stay permanent (the server will keep rejecting them).
        XCTAssertEqual(Attriloop.classify(code: 400, error: nil), .permanent)
        XCTAssertEqual(Attriloop.classify(code: 404, error: nil), .permanent)
        XCTAssertEqual(Attriloop.classify(code: 422, error: nil), .permanent)
    }

    func testClassifyTransientOnNetworkError() {
        let err = NSError(domain: "net", code: -1009)
        XCTAssertEqual(Attriloop.classify(code: 0, error: err), .transient)
        // An error always wins, even alongside a 2xx code.
        XCTAssertEqual(Attriloop.classify(code: 200, error: err), .transient)
    }

    // MARK: - queue cap + removeQueued

    private func queue() -> [[String: Any]] {
        suite.array(forKey: "com.attriloop.queue") as? [[String: Any]] ?? []
    }

    func testEnqueueCapsAtMaxDroppingOldest() {
        for i in 0..<505 { Attriloop.shared.enqueue(["eid": "e\(i)"]) }
        let q = queue()
        XCTAssertEqual(q.count, 500)
        XCTAssertEqual(q.first?["eid"] as? String, "e5") // e0..e4 evicted
        XCTAssertEqual(q.last?["eid"] as? String, "e504")
    }

    func testRemoveQueuedByEidRemovesTheRightItem() {
        ["a", "b", "c"].forEach { Attriloop.shared.enqueue(["eid": $0]) }
        Attriloop.shared.removeQueued(eid: "b") // middle, not head
        XCTAssertEqual(queue().compactMap { $0["eid"] as? String }, ["a", "c"])
    }

    func testRemoveQueuedNilEidFallsBackToHead() {
        ["a", "b"].forEach { Attriloop.shared.enqueue(["eid": $0]) }
        Attriloop.shared.removeQueued(eid: nil)
        XCTAssertEqual(queue().compactMap { $0["eid"] as? String }, ["b"])
    }

    func testRemoveQueuedMissingEidRemovesNothing() {
        // Simulates an in-flight event that was cap-evicted before its POST returned: the
        // eid is no longer in the queue, so removeQueued must NOT drop an unrelated head.
        ["a", "b"].forEach { Attriloop.shared.enqueue(["eid": $0]) }
        Attriloop.shared.removeQueued(eid: "evicted")
        XCTAssertEqual(queue().compactMap { $0["eid"] as? String }, ["a", "b"]) // unchanged
    }

    // MARK: - SKAdNetwork / AdAttributionKit conversion value

    private func convSchema() -> Attriloop.ConversionSchema {
        Attriloop.ConversionSchema(
            version: 1,
            rules: [
                .init(event: "SIGN_UP", fine: 1, coarse: "low", lockWindow: false, priority: 1),
                .init(event: "PURCHASE", fine: 40, coarse: "high", lockWindow: true, priority: 10),
                .init(event: "PURCHASE", fine: 20, coarse: "medium", lockWindow: false, priority: 1),
                .init(event: "SUBSCRIBE", fine: 30, coarse: "medium", lockWindow: false, priority: 5),
            ],
            installCoarse: "low"
        )
    }

    private func startState() -> Attriloop.ConversionState {
        .init(fine: 0, coarse: "low")
    }

    func testFoldAppliesMatchingRule() {
        let r = Attriloop.foldConversion(convSchema(), startState(), event: "SIGN_UP")
        XCTAssertEqual(r.state, Attriloop.ConversionState(fine: 1, coarse: "low"))
        XCTAssertFalse(r.lockWindow)
    }

    func testFoldPicksHighestPriorityRuleAndLocks() {
        let r = Attriloop.foldConversion(convSchema(), startState(), event: "PURCHASE")
        XCTAssertEqual(r.state, Attriloop.ConversionState(fine: 40, coarse: "high"))
        XCTAssertTrue(r.lockWindow)
    }

    func testFoldNeverDecreasesFineOrCoarse() {
        let high = Attriloop.ConversionState(fine: 40, coarse: "high")
        let r = Attriloop.foldConversion(convSchema(), high, event: "SUBSCRIBE") // rule fine=30, coarse=medium
        XCTAssertEqual(r.state, high) // unchanged — monotonic
    }

    func testFoldNoMatchLeavesStateAndDoesNotLock() {
        let s = startState()
        let r = Attriloop.foldConversion(convSchema(), s, event: "LEVEL_START")
        XCTAssertEqual(r.state, s)
        XCTAssertFalse(r.lockWindow)
    }

    func testFoldClampsFineToSKANMax63() {
        // A misconfigured schema with fine > 63 must be clamped, not persisted verbatim
        // (an out-of-range value is rejected by the OS and would poison all later reports).
        let schema = Attriloop.ConversionSchema(
            version: 1,
            rules: [.init(event: "PURCHASE", fine: 9999, coarse: "high", lockWindow: false, priority: 1)],
            installCoarse: "low"
        )
        let r = Attriloop.foldConversion(schema, startState(), event: "PURCHASE")
        XCTAssertEqual(r.state.fine, 63) // clamped to the valid SKAdNetwork ceiling
    }

    func testFoldDoesNotLockOnNoOpReFire() {
        let already = Attriloop.ConversionState(fine: 40, coarse: "high")
        let r = Attriloop.foldConversion(convSchema(), already, event: "PURCHASE")
        XCTAssertFalse(r.lockWindow) // value didn't advance → no lock
    }

    func testConversionStateRoundTripsThroughDefaults() {
        Attriloop.shared.defaults = suite
        XCTAssertEqual(Attriloop.shared.loadConversionState(), Attriloop.ConversionState(fine: 0, coarse: "low"))
        suite.set(["fine": 40, "coarse": "high"], forKey: Attriloop.shared.convStateKey)
        XCTAssertEqual(Attriloop.shared.loadConversionState(), Attriloop.ConversionState(fine: 40, coarse: "high"))
    }

    func testLoadConversionSchemaDecodesCachedJSON() throws {
        Attriloop.shared.defaults = suite
        let json = """
        {"version":2,"installCoarse":"low","rules":[{"event":"PURCHASE","fine":50,"coarse":"high","lockWindow":true,"priority":9}]}
        """.data(using: .utf8)!
        suite.set(json, forKey: Attriloop.shared.convSchemaKey)
        let schema = try XCTUnwrap(Attriloop.shared.loadConversionSchema())
        XCTAssertEqual(schema.version, 2)
        XCTAssertEqual(schema.rules.first?.fine, 50)
    }

    // MARK: - coerceNonNegNumber (B3)

    func testCoerceNonNegNumberAcceptsNumericTypes() {
        XCTAssertEqual(Attriloop.coerceNonNegNumber(9.99), 9.99)
        XCTAssertEqual(Attriloop.coerceNonNegNumber(5), 5)
        XCTAssertEqual(Attriloop.coerceNonNegNumber(NSNumber(value: 7)), 7)
        XCTAssertEqual(Attriloop.coerceNonNegNumber("29.99"), 29.99) // numeric string coerced
        XCTAssertEqual(Attriloop.coerceNonNegNumber(0), 0)
    }

    func testCoerceNonNegNumberRejectsBadValues() {
        XCTAssertNil(Attriloop.coerceNonNegNumber(-1)) // negative
        XCTAssertNil(Attriloop.coerceNonNegNumber("abc")) // non-numeric string
        XCTAssertNil(Attriloop.coerceNonNegNumber("")) // empty
        XCTAssertNil(Attriloop.coerceNonNegNumber(Double.infinity)) // non-finite
        XCTAssertNil(Attriloop.coerceNonNegNumber(nil))
        XCTAssertNil(Attriloop.coerceNonNegNumber(true as Any)) // Bool is not a revenue number
    }

    // MARK: - validatedParams (B3) — degrade instead of 422-dropping the event

    func testValidatedParamsCoercesStringRevenue() {
        let out = Attriloop.validatedParams(["revenue": "9.99", "currency": "USD"])
        XCTAssertEqual(out["revenue"] as? Double, 9.99)
        XCTAssertEqual(out["currency"] as? String, "USD")
    }

    func testValidatedParamsDropsBadRevenueKeepsEvent() {
        // Negative revenue would 422 the whole event → we drop just the key.
        let out = Attriloop.validatedParams(["revenue": -5, "level": 3])
        XCTAssertNil(out["revenue"])
        XCTAssertEqual(out["level"] as? Int, 3) // rest of the event survives
    }

    func testValidatedParamsDropsMalformedCurrency() {
        XCTAssertNil(Attriloop.validatedParams(["currency": "US"])["currency"]) // 2 letters
        XCTAssertNil(Attriloop.validatedParams(["currency": "US$"])["currency"]) // non-letter
        XCTAssertEqual(Attriloop.validatedParams(["currency": "eur"])["currency"] as? String, "eur")
    }

    // MARK: - deepStripNSNull (B4) — nested null would crash UserDefaults.set

    func testDeepStripNSNullRemovesNestedNulls() {
        let cleaned = Attriloop.deepStripNSNull([
            "a": 1,
            "b": NSNull(),
            "nested": ["keep": "x", "drop": NSNull()],
            "list": [1, NSNull(), 2],
        ]) as? [String: Any]
        XCTAssertEqual(cleaned?["a"] as? Int, 1)
        XCTAssertNil(cleaned?["b"])
        let nested = cleaned?["nested"] as? [String: Any]
        XCTAssertEqual(nested?["keep"] as? String, "x")
        XCTAssertNil(nested?["drop"])
        XCTAssertEqual((cleaned?["list"] as? [Any])?.count, 2) // NSNull removed from array
    }

    func testValidatedParamsStripsNestedNSNull() {
        let out = Attriloop.validatedParams(["meta": ["k": NSNull(), "ok": 1]])
        let meta = out["meta"] as? [String: Any]
        XCTAssertNil(meta?["k"])
        XCTAssertEqual(meta?["ok"] as? Int, 1)
    }

    // MARK: - interpretTestResponse (sendTestEvent verdict mapping)

    private func httpResponse(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://e.test/v1/test")!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func testInterpretTestResponseSuccessUsesServerMessage() {
        let body = #"{"ok":true,"message":"SDK connected — test event received."}"#.data(using: .utf8)
        let r = Attriloop.interpretTestResponse(data: body, response: httpResponse(200), error: nil)
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.message, "SDK connected — test event received.")
    }

    func testInterpretTestResponseUnauthorized() {
        let r = Attriloop.interpretTestResponse(data: nil, response: httpResponse(401), error: nil)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.message.contains("401"))
    }

    func testInterpretTestResponseNetworkErrorIsUnreachable() {
        let err = NSError(domain: NSURLErrorDomain, code: -1004) // cannot connect to host
        let r = Attriloop.interpretTestResponse(data: nil, response: nil, error: err)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.message.lowercased().contains("reach"))
    }
}
