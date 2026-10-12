/// Validation errors for portable session inputs, not equipment/protocol guarantees.
public enum SessionInputError: Error, Equatable, Sendable {
    case invalidConfiguration
    case emptyDeviceID
    case invalidSnapshot
}

/// Explicit app policy; no hardware-derived timing defaults.
public struct SessionConfiguration: Equatable, Sendable {
    public let staleAfter: Double
    public let phaseTimeout: Double
    public let requiresAuthentication: Bool

    public init(staleAfter: Double, phaseTimeout: Double, requiresAuthentication: Bool) throws {
        guard staleAfter.isFinite, staleAfter > 0, phaseTimeout.isFinite, phaseTimeout > 0 else {
            throw SessionInputError.invalidConfiguration
        }
        self.staleAfter = staleAfter
        self.phaseTimeout = phaseTimeout
        self.requiresAuthentication = requiresAuthentication
    }
}

/// An immutable numeric display snapshot. Keys/units/physical validity belong to the adapter.
/// Only include independently validated measurements, never missing-value sentinels.
public struct SessionSnapshot: Equatable, Sendable {
    public let values: [String: Double]

    public init(values: [String: Double]) throws {
        guard !values.isEmpty, values.allSatisfy({ !$0.key.isEmpty && $0.value.isFinite }) else {
            throw SessionInputError.invalidSnapshot
        }
        self.values = values
    }
}

/// Capture this token in every callback; never substitute the current token for an old callback.
/// Tokens are scoped to the lifetime of one SessionState owner, not a global transport identity.
public struct ConnectionAttempt: Equatable, Sendable {
    public let deviceID: String
    public let generation: UInt64
}

public enum SessionFailure: Equatable, Sendable {
    case transport, subscription, authenticationRejected, timeout, invalidTime, generationExhausted
}

public enum ConnectionPhase: Equatable, Sendable {
    case disconnected, connecting, subscribing, authenticating, ready
    case error(SessionFailure)
}

/// Intent only: no BLE sends, command queues, authentication writes, or device control.
public enum SessionAction: Equatable, Sendable {
    case none, scan
    case connect(ConnectionAttempt)
}

public enum ReadingFreshness: Equatable, Sendable { case absent, stale, live }

public struct SessionReading: Equatable, Sendable {
    public let snapshot: SessionSnapshot
    public let observedAt: Double
    public let attempt: ConnectionAttempt
}

/// Sequential value state. An iOS adapter should own one instance on a single actor/queue.
/// All times are injected finite, nonnegative seconds in the same monotonic clock domain.
public struct SessionState: Equatable, Sendable {
    public let configuration: SessionConfiguration
    public private(set) var savedDeviceID: String?
    public private(set) var phase: ConnectionPhase = .disconnected
    public private(set) var attempt: ConnectionAttempt?
    public private(set) var reading: SessionReading?

    private var generation: UInt64 = 0
    private var lastTime: Double?
    private var phaseStartedAt: Double?
    private var readingInvalidated = true

    public init(savedDeviceID: String?, configuration: SessionConfiguration) throws {
        guard savedDeviceID != "" else { throw SessionInputError.emptyDeviceID }
        self.savedDeviceID = savedDeviceID
        self.configuration = configuration
    }

    /// Call on launch or an explicitly scheduled retry after disconnect/error.
    /// First run requests discovery, never automatically chooses a discovered peripheral.
    public mutating func launch(at now: Double) -> SessionAction {
        guard advanceTime(now) else { return .none }
        guard !isActive else { return .none }
        guard let deviceID = savedDeviceID else { return .scan }
        return begin(deviceID, at: now)
    }

    /// A deliberate adapter selection after checking compatibility; unsupported IDs are ignored.
    /// Replaces any current attempt; adapter must cancel its old transport independently.
    public mutating func selectDevice(_ deviceID: String, supported: Bool, at now: Double) -> SessionAction {
        guard supported, !deviceID.isEmpty else { return .none }
        guard advanceTime(now) else { return .none }
        let action = begin(deviceID, at: now)
        if case .connect = action { savedDeviceID = deviceID }
        return action
    }

    @discardableResult
    public mutating func connected(_ source: ConnectionAttempt, at now: Double) -> Bool {
        guard accepts(source, at: now), phase == .connecting else { return false }
        transition(to: .subscribing, at: now)
        return true
    }

    @discardableResult
    public mutating func subscribed(_ source: ConnectionAttempt, at now: Double) -> Bool {
        guard accepts(source, at: now), phase == .subscribing else { return false }
        transition(to: configuration.requiresAuthentication ? .authenticating : .ready, at: now)
        return true
    }

    @discardableResult
    public mutating func authenticated(_ source: ConnectionAttempt, at now: Double) -> Bool {
        guard accepts(source, at: now), phase == .authenticating else { return false }
        transition(to: .ready, at: now)
        return true
    }

    @discardableResult
    public mutating func disconnected(_ source: ConnectionAttempt, at now: Double) -> Bool {
        guard accepts(source, at: now) else { return false }
        transition(to: .disconnected, at: now)
        readingInvalidated = true
        return true
    }

    @discardableResult
    public mutating func failed(_ source: ConnectionAttempt, reason: SessionFailure, at now: Double) -> Bool {
        guard accepts(source, at: now) else { return false }
        fail(reason)
        return true
    }

    /// Only a new, valid reading for the current ready attempt can restore live status.
    /// observedAt is receipt/observation time in the injected clock domain, not wall time.
    @discardableResult
    public mutating func receive(_ snapshot: SessionSnapshot, from source: ConnectionAttempt,
                                 observedAt: Double, at now: Double) -> Bool {
        guard accepts(source, at: now), phase == .ready else { return false }
        guard observedAt.isFinite, observedAt >= 0, observedAt <= now,
              let readyAt = phaseStartedAt, observedAt >= readyAt,
              now - observedAt < configuration.staleAfter,
              reading?.attempt != source || observedAt > (reading?.observedAt ?? -1) else {
            readingInvalidated = true
            return false
        }
        reading = SessionReading(snapshot: snapshot, observedAt: observedAt, attempt: source)
        readingInvalidated = false
        return true
    }

    /// Use when checksum/decoder/model validation rejects a measurement before snapshot creation.
    /// An unrelated notification should simply not call this measurement-specific method.
    @discardableResult
    public mutating func rejectReading(from source: ConnectionAttempt, at now: Double) -> Bool {
        guard accepts(source, at: now), phase == .ready else { return false }
        readingInvalidated = true
        return true
    }

    /// Adapter supplies periodic ticks, including after app resume; no timers or sleeps here.
    public mutating func tick(at now: Double) {
        _ = advanceTime(now)
    }

    /// Display evaluation also advances time, persisting expiration and clock failures.
    /// This prevents an older display evaluation from making an expired sample live again.
    public mutating func freshness(at now: Double) -> ReadingFreshness {
        let timeAccepted = advanceTime(now)
        guard let reading else { return .absent }
        guard timeAccepted, phase == .ready, !readingInvalidated,
              reading.attempt == attempt, now >= reading.observedAt,
              now - reading.observedAt < configuration.staleAfter else { return .stale }
        return .live
    }

    private var isActive: Bool {
        switch phase {
        case .connecting, .subscribing, .authenticating, .ready: return true
        case .disconnected, .error: return false
        }
    }

    private mutating func begin(_ deviceID: String, at now: Double) -> SessionAction {
        guard generation < UInt64.max else {
            fail(.generationExhausted)
            return .none
        }
        generation += 1
        let token = ConnectionAttempt(deviceID: deviceID, generation: generation)
        attempt = token
        readingInvalidated = true
        transition(to: .connecting, at: now)
        return .connect(token)
    }

    private mutating func transition(to next: ConnectionPhase, at now: Double) {
        phase = next
        phaseStartedAt = now
    }

    private mutating func fail(_ reason: SessionFailure) {
        phase = .error(reason)
        readingInvalidated = true
    }

    private func validTime(_ now: Double) -> Bool {
        now.isFinite && now >= 0 && (lastTime.map { now >= $0 } ?? true)
    }

    private mutating func advanceTime(_ now: Double) -> Bool {
        guard validTime(now) else {
            fail(.invalidTime)
            return false
        }
        lastTime = now
        switch phase {
        case .connecting, .subscribing, .authenticating:
            if let start = phaseStartedAt, now - start >= configuration.phaseTimeout { fail(.timeout) }
        default: break
        }
        if let reading, now - reading.observedAt >= configuration.staleAfter {
            readingInvalidated = true
        }
        return true
    }

    private mutating func accepts(_ source: ConnectionAttempt, at now: Double) -> Bool {
        // Reject foreign/terminal callbacks before looking at their timestamps.
        guard source == attempt, isActive else { return false }
        guard advanceTime(now) else { return false }
        return isActive
    }
}
