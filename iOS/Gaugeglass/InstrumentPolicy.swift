import Foundation
import GaugeglassCore

/// Exact reachable source-name tokens, restricted to the portable decoder's families.
/// A name/service is a compatibility hint, NEVER authenticated equipment identity.
enum DeviceProfile {
    static let names: [(String, MeasurementFamily)] = [
        ("NAVAC-NST1", .lowTemperatureClamp), ("NAVAC-NST2", .highTemperatureClamp),
        ("NAVAC-NP8D 1S", .vacuumPump), ("NAVAC-NP8DS(V)", .vacuumPump),
        ("NAVAC-NMGD1", .digitalManifold), ("NAVAC-NX1-", .digitalManifold),
        ("NAVAC-NMV 1S", .vacuumGauge), ("NAVAC-NMV1S", .vacuumGauge),
        ("NAVAC-NX4-", .fourValveManifold), ("NAVAC-NST3", .largeTemperatureClamp),
        ("NAVAC-NSTL", .largeTemperatureClamp), ("NAVAC-NSH1", .temperatureHumidity),
        ("VALUE-VSH1", .temperatureHumidity), ("NAVAC-NX1G-", .manifold29),
        ("NAVAC-NX4G-", .manifold34), ("NAVAC-N1DXI-", .manifold35)
    ]
    static func match(_ name: String) -> MeasurementFamily? {
        let matches = Set(names.filter { name.contains($0.0) }.map { $0.1.rawValue })
        guard matches.count == 1, let category = matches.first else { return nil }
        return MeasurementFamily(rawValue: category)
    }
}

struct SavedDevice: Codable, Equatable {
    let id: UUID
    let name: String
    let category: Int
    var isSupported: Bool {
        MeasurementFamily(rawValue: category) != nil && DeviceProfile.match(name)?.rawValue == category
    }
}

enum AuthOnly {
    // Source request: handle 00, unresolved length 04, cmd 01, subcmd 00, marker A55A.
    // BCC produced by the independent core; observed source semantics, not hardware verified.
    static let request = Packet(handle: 0, rawLength: 4, command: 1, payload: [0, 0xA5, 0x5A])
    static func permits(_ packet: Packet) -> Bool {
        guard packet.isChecksumValid else { return false }
        if packet == request { return true }
        return packet.handle == 1 && packet.rawLength == 3 && packet.command == 1
            && packet.payload.count == 2 && packet.payload[0] == 2
    }
}

struct FieldEntry: Equatable {
    let field: MeasurementField
    let observedAt: Double
    let attempt: ConnectionAttempt
    var invalidated: Bool = false
}

/// Freshness is independent per field. A battery report cannot refresh an old pressure.
struct FieldStore {
    private(set) var entries: [MeasurementKey: FieldEntry] = [:]
    mutating func apply(_ report: MeasurementReport, attempt: ConnectionAttempt, at now: Double) {
        guard report.isComplete, report.packet.isChecksumValid, report.packet.command == 3,
              report.context.family != nil, now.isFinite, now >= 0 else { return }
        for field in report.fields {
            switch field.value {
            case .number(let number) where number.value.isFinite:
                entries[field.key] = FieldEntry(field: field, observedAt: now, attempt: attempt)
            case .missing: entries.removeValue(forKey: field.key)
            default: break // opaque metadata never becomes a numeric instrument reading
            }
        }
    }
    mutating func invalidate() {
        for key in Array(entries.keys) { entries[key]?.invalidated = true }
    }
    mutating func clear() { entries.removeAll() }
    mutating func removeTemperatures() {
        entries = entries.filter {
            ![MeasurementSemantic.temperature, .lowTemperature, .highTemperature].contains($0.value.field.semantic)
        }
    }
    func isLive(_ key: MeasurementKey, attempt: ConnectionAttempt?, ready: Bool,
                at now: Double, staleAfter: Double) -> Bool {
        guard let entry = entries[key] else { return false }
        return ready && !entry.invalidated && entry.attempt == attempt && now >= entry.observedAt
            && now - entry.observedAt < staleAfter
    }
}

enum RetryPolicy {
    /// At most three scheduled retries per foreground/manual activation. No automatic reset
    /// on transient auth success (a flapping device must not retry forever).
    static func delay(afterFailures count: Int) -> Double? {
        switch count { case 1: return 2; case 2: return 4; case 3: return 8; default: return nil }
    }
}
