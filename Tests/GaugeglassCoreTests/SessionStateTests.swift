import XCTest
@testable import GaugeglassCore

/// Synthetic state-machine fixtures; not captured equipment readings.
final class SessionStateTests: XCTestCase {
    private func make(_ remembered: String? = "meter-A", auth: Bool = true) throws -> SessionState {
        try SessionState(savedDeviceID: remembered, configuration: SessionConfiguration(
            staleAfter: 5, phaseTimeout: 10, requiresAuthentication: auth))
    }

    private func ready(_ state: inout SessionState, at start: Double = 0) throws -> ConnectionAttempt {
        guard case let .connect(attempt) = state.launch(at: start) else {
            throw TestError.noAttempt
        }
        XCTAssertTrue(state.connected(attempt, at: start + 1))
        XCTAssertTrue(state.subscribed(attempt, at: start + 2))
        if state.configuration.requiresAuthentication {
            XCTAssertTrue(state.authenticated(attempt, at: start + 3))
        }
        XCTAssertEqual(state.phase, .ready)
        return attempt
    }

    private func snapshot(_ value: Double = 42) throws -> SessionSnapshot {
        try SessionSnapshot(values: ["synthetic": value])
    }

    func testLaunchReconnectsOnlyRememberedDeviceAndFirstRunScans() throws {
        var saved = try make()
        guard case let .connect(attempt) = saved.launch(at: 0) else { return XCTFail("No reconnect") }
        XCTAssertEqual(attempt.deviceID, "meter-A")
        XCTAssertEqual(saved.phase, .connecting)
        XCTAssertEqual(saved.launch(at: 1), .none)
        var first = try make(nil)
        XCTAssertEqual(first.launch(at: 0), .scan)
        XCTAssertEqual(first.phase, .disconnected)
        XCTAssertNil(first.attempt)
        XCTAssertEqual(first.selectDevice("unknown", supported: false, at: 1), .none)
        XCTAssertNil(first.savedDeviceID)
        guard case let .connect(selected) = first.selectDevice("meter-B", supported: true, at: 2) else {
            return XCTFail("Explicit supported selection should connect")
        }
        XCTAssertEqual(selected.deviceID, "meter-B")
        XCTAssertEqual(first.savedDeviceID, "meter-B")
    }

    func testConnectedIsNotReadyAndConservativeSubscriptionAuthOrder() throws {
        var state = try make()
        guard case let .connect(a) = state.launch(at: 0) else { return XCTFail() }
        XCTAssertFalse(state.authenticated(a, at: 1))
        XCTAssertFalse(state.subscribed(a, at: 1))
        XCTAssertTrue(state.connected(a, at: 1))
        XCTAssertEqual(state.phase, .subscribing)
        XCTAssertFalse(state.authenticated(a, at: 2))
        XCTAssertFalse(state.receive(try snapshot(), from: a, observedAt: 2, at: 2))
        XCTAssertTrue(state.subscribed(a, at: 2))
        XCTAssertEqual(state.phase, .authenticating)
        XCTAssertTrue(state.authenticated(a, at: 3))
        XCTAssertFalse(state.connected(a, at: 4))
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.freshness(at: 4), .absent)
    }

    func testExplicitNoAuthConfigurationStillRequiresSubscription() throws {
        var state = try make(auth: false)
        let a = try ready(&state)
        XCTAssertFalse(state.authenticated(a, at: 3))
        XCTAssertTrue(state.receive(try snapshot(), from: a, observedAt: 3, at: 3))
        XCTAssertEqual(state.freshness(at: 3), .live)
    }

    func testRetainedReadingStaysStaleThroughDisconnectAndReconnect() throws {
        var state = try make()
        let old = try ready(&state)
        XCTAssertTrue(state.receive(try snapshot(), from: old, observedAt: 4, at: 4))
        let retained = state.reading
        XCTAssertEqual(state.freshness(at: 4), .live)
        XCTAssertTrue(state.disconnected(old, at: 5))
        XCTAssertEqual(state.reading, retained)
        XCTAssertEqual(state.freshness(at: 5), .stale)
        let new = try ready(&state, at: 6)
        XCTAssertNotEqual(new, old)
        XCTAssertEqual(state.reading, retained)
        XCTAssertEqual(state.freshness(at: 9), .stale)
        XCTAssertTrue(state.receive(try snapshot(43), from: new, observedAt: 10, at: 10))
        XCTAssertEqual(state.freshness(at: 10), .live)
        XCTAssertEqual(state.reading?.snapshot.values["synthetic"], 43)
    }

    func testAgeBoundaryAndExplicitTicks() throws {
        var state = try make()
        let a = try ready(&state)
        XCTAssertTrue(state.receive(try snapshot(), from: a, observedAt: 4, at: 4))
        XCTAssertEqual(state.freshness(at: 8.999), .live)
        XCTAssertEqual(state.freshness(at: 9), .stale)
        state.tick(at: 9)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.freshness(at: 9), .stale)
        XCTAssertTrue(state.receive(try snapshot(44), from: a, observedAt: 9.1, at: 9.1))
        XCTAssertEqual(state.freshness(at: 9.1), .live)
    }

    func testPhaseTimeoutBoundaryCannotBeBypassedByLateCallback() throws {
        for phaseStep in 0...2 {
            var state = try make()
            guard case let .connect(a) = state.launch(at: 0) else { return XCTFail() }
            if phaseStep >= 1 { XCTAssertTrue(state.connected(a, at: 1)) }
            if phaseStep >= 2 { XCTAssertTrue(state.subscribed(a, at: 2)) }
            state.tick(at: Double(phaseStep) + 9.999)
            XCTAssertNotEqual(state.phase, .error(.timeout))
            let accepted: Bool
            switch phaseStep {
            case 0: accepted = state.connected(a, at: 10)
            case 1: accepted = state.subscribed(a, at: 11)
            default: accepted = state.authenticated(a, at: 12)
            }
            XCTAssertFalse(accepted)
            XCTAssertEqual(state.phase, .error(.timeout))
        }
    }

    func testOldGenerationAndDifferentDeviceEventsCannotChangeState() throws {
        var state = try make()
        let old = try ready(&state)
        XCTAssertTrue(state.receive(try snapshot(), from: old, observedAt: 4, at: 4))
        XCTAssertTrue(state.disconnected(old, at: 5))
        guard case let .connect(new) = state.selectDevice("meter-B", supported: true, at: 6) else { return XCTFail() }
        XCTAssertTrue(state.connected(new, at: 7))
        XCTAssertTrue(state.subscribed(new, at: 8))
        XCTAssertTrue(state.authenticated(new, at: 9))
        let retained = state.reading
        XCTAssertFalse(state.receive(try snapshot(99), from: old, observedAt: 10, at: .infinity))
        XCTAssertFalse(state.failed(old, reason: .transport, at: 10))
        XCTAssertFalse(state.disconnected(old, at: 10))
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.reading, retained)
        XCTAssertEqual(state.freshness(at: 10), .stale)
        XCTAssertTrue(state.receive(try snapshot(45), from: new, observedAt: 10, at: 10))
        XCTAssertEqual(state.freshness(at: 10), .live)
    }

    func testFailureIsTerminalUntilExplicitRetryAndRetainsReading() throws {
        var state = try make()
        let a = try ready(&state)
        XCTAssertTrue(state.receive(try snapshot(), from: a, observedAt: 4, at: 4))
        let retained = state.reading
        XCTAssertTrue(state.failed(a, reason: .authenticationRejected, at: 5))
        XCTAssertEqual(state.phase, .error(.authenticationRejected))
        XCTAssertFalse(state.authenticated(a, at: 6))
        XCTAssertFalse(state.receive(try snapshot(), from: a, observedAt: 6, at: 6))
        XCTAssertEqual(state.reading, retained)
        XCTAssertEqual(state.freshness(at: 6), .stale)
        guard case let .connect(next) = state.launch(at: 7) else { return XCTFail() }
        XCTAssertNotEqual(next, a)
    }

    func testInvalidConfigurationAndSnapshotsAreRejected() throws {
        for invalid in [0, -1, Double.nan, .infinity] {
            XCTAssertThrowsError(try SessionConfiguration(staleAfter: invalid, phaseTimeout: 10, requiresAuthentication: true))
            XCTAssertThrowsError(try SessionConfiguration(staleAfter: 5, phaseTimeout: invalid, requiresAuthentication: true))
        }
        XCTAssertThrowsError(try SessionSnapshot(values: [:]))
        XCTAssertThrowsError(try SessionSnapshot(values: ["": 1]))
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try SessionSnapshot(values: ["synthetic": invalid]))
        }
        XCTAssertThrowsError(try make(""))
    }

    func testInvalidObservedTimesInvalidateButNeverReplaceRetainedSample() throws {
        for observed in [Double.nan, .infinity, -1, 3, 4, 6] {
            var state = try make()
            let a = try ready(&state)
            XCTAssertTrue(state.receive(try snapshot(), from: a, observedAt: 4, at: 4))
            let retained = state.reading
            XCTAssertFalse(state.receive(try snapshot(99), from: a, observedAt: observed, at: 5))
            XCTAssertEqual(state.reading, retained)
            XCTAssertEqual(state.freshness(at: 5), .stale)
            XCTAssertTrue(state.receive(try snapshot(46), from: a, observedAt: 5.1, at: 5.1))
            XCTAssertEqual(state.freshness(at: 5.1), .live)
        }
    }

    func testInvalidOrBackwardClockFailsClosedUntilNewAttempt() throws {
        for now in [Double.nan, .infinity, -.infinity, -1, 3] {
            var state = try make()
            let a = try ready(&state)
            XCTAssertTrue(state.receive(try snapshot(), from: a, observedAt: 4, at: 4))
            XCTAssertEqual(state.freshness(at: now), .stale)
            state.tick(at: now)
            XCTAssertEqual(state.phase, .error(.invalidTime))
            XCTAssertEqual(state.freshness(at: 5), .stale)
            XCTAssertFalse(state.receive(try snapshot(), from: a, observedAt: 5, at: 5))
            let next = try ready(&state, at: 6)
            XCTAssertTrue(state.receive(try snapshot(), from: next, observedAt: 10, at: 10))
            XCTAssertEqual(state.freshness(at: 10), .live)
        }
    }

    func testDelayedSampleAlreadyAtStaleBoundaryCannotBecomeLive() throws {
        var state = try make()
        let a = try ready(&state)
        XCTAssertFalse(state.receive(try snapshot(), from: a, observedAt: 3, at: 8))
        XCTAssertNil(state.reading)
        XCTAssertEqual(state.phase, .ready)
    }

    func testRejectedDecodeAndSameDeviceOldGenerationCannotRefresh() throws {
        var state = try make()
        let old = try ready(&state)
        XCTAssertTrue(state.receive(try snapshot(), from: old, observedAt: 4, at: 4))
        XCTAssertTrue(state.rejectReading(from: old, at: 5))
        XCTAssertEqual(state.freshness(at: 5), .stale)
        XCTAssertTrue(state.disconnected(old, at: 6))
        let current = try ready(&state, at: 7)
        XCTAssertEqual(current.deviceID, old.deviceID)
        XCTAssertNotEqual(current.generation, old.generation)
        XCTAssertFalse(state.receive(try snapshot(99), from: old, observedAt: 11, at: 11))
        XCTAssertFalse(state.rejectReading(from: old, at: 11))
        XCTAssertTrue(state.receive(try snapshot(47), from: current, observedAt: 11, at: 11))
        let wrongDevice = ConnectionAttempt(deviceID: "other", generation: current.generation)
        XCTAssertFalse(state.receive(try snapshot(99), from: wrongDevice, observedAt: 12, at: 12))
        XCTAssertEqual(state.freshness(at: 12), .live)
    }

    func testSnapshotIsAnImmutableCopyAndSampleCarriesIdentityAndTime() throws {
        var values = ["synthetic": 42.0]
        let immutable = try SessionSnapshot(values: values)
        values["synthetic"] = 99
        var state = try make()
        let a = try ready(&state)
        XCTAssertTrue(state.receive(immutable, from: a, observedAt: 4, at: 4.5))
        XCTAssertEqual(state.reading?.snapshot.values["synthetic"], 42)
        XCTAssertEqual(state.reading?.observedAt, 4)
        XCTAssertEqual(state.reading?.attempt, a)
        XCTAssertEqual(state.freshness(at: 9), .stale)
    }

    func testDisplayQueriesCannotResurrectExpiredReadingByMovingClockBackward() throws {
        var state = try make()
        let a = try ready(&state)
        XCTAssertTrue(state.receive(try snapshot(), from: a, observedAt: 4, at: 4))
        XCTAssertEqual(state.freshness(at: 9), .stale)
        XCTAssertEqual(state.freshness(at: 8), .stale)
        XCTAssertEqual(state.phase, .error(.invalidTime))
        XCTAssertEqual(state.freshness(at: 10), .stale)
    }

    private enum TestError: Error { case noAttempt }
}
