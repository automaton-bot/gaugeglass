import Foundation
import GaugeglassCore

@main struct PolicyChecks {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
        }
        check(DeviceProfile.match("NAVAC-NX4G-123")?.rawValue == 34, "reachable NX4G mapping")
        check(DeviceProfile.match("NAVAC-N1DXI-123")?.rawValue == 35, "literal capital I")
        check(DeviceProfile.match("NAVAC-N1DX1-123") == nil, "do not repair token")
        check(DeviceProfile.match("NAVAC-NMA1-123") == nil, "unsupported analyzer")
        check(DeviceProfile.match("NAVAC-NSP1") == nil, "unsupported category 11")
        check(DeviceProfile.match("NAVAC-VRSV1") == nil, "no valve profile")
        check(DeviceProfile.match("navac-nx4g-123") == nil, "case sensitive")
        check(DeviceProfile.match("unknown") == nil, "no arbitrary device")
        check(DeviceProfile.match("NAVAC-NST1 NAVAC-NST2") == nil, "ambiguous advertisement rejected")
        check(Set(DeviceProfile.names.map { $0.1.rawValue }) == Set(MeasurementFamily.allCases.map(\.rawValue)), "discovery supports only/every implemented family")
        for (token, family) in DeviceProfile.names {
            check(DeviceProfile.match(token)?.rawValue == family.rawValue, "literal reachable name map")
        }
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        check(SavedDevice(id: id, name: "NAVAC-NX4G-123", category: 34).isSupported, "valid persisted profile")
        check(!SavedDevice(id: id, name: "NAVAC-NX4G-123", category: 35).isSupported, "persisted profile mismatch rejected")
        check(!SavedDevice(id: id, name: "NAVAC-NSP1", category: 11).isSupported, "persisted unsupported profile rejected")
        check(AuthOnly.request.hex == "00040100A55A06", "observed initial auth request")
        check(AuthOnly.permits(AuthOnly.request), "auth request allowed")
        let challenge = try AuthenticationChallenge(bytes: [1, 2, 3, 4])
        check(AuthOnly.permits(challenge.reply), "auth reply allowed")
        check(!AuthOnly.permits(Packet(handle: 0, rawLength: 1, command: 2, payload: [0])), "settings blocked")
        check(!AuthOnly.permits(Packet(handle: 0, rawLength: 1, command: 5, payload: [0])), "controls blocked")
        check(!AuthOnly.permits(Packet(handle: 0, rawLength: 4, command: 1, payload: [0, 0, 0])), "arbitrary auth bytes blocked")
        let config = try SessionConfiguration(staleAfter: 5, phaseTimeout: 20, requiresAuthentication: true)
        var session = try SessionState(savedDeviceID: "A", configuration: config)
        guard case .connect(let first) = session.launch(at: 0) else { fatalError("token") }
        var store = FieldStore()
        func report(_ payload: [UInt8], unit: MeasurementTemperatureUnit = .unknown) throws -> MeasurementReport {
            try Measurements.decode(Packet(handle: 0, rawLength: 0, command: 3, payload: payload),
                                    context: MeasurementContext(category: 34, temperatureUnit: unit))
        }
        let pressure = try report([1, 5, 0, 100, 0, 0, 0])
        store.apply(pressure, attempt: first, at: 1)
        let pressureKey = MeasurementKey(5, 0)
        check(store.isLive(pressureKey, attempt: first, ready: true, at: 2, staleAfter: 5), "fresh pressure")
        store.apply(try report([1, 0x10, 0, 80]), attempt: first, at: 4)
        check(store.entries[pressureKey]?.observedAt == 1, "battery must not refresh pressure")
        check(!store.isLive(pressureKey, attempt: first, ready: true, at: 6, staleAfter: 5), "pressure expires independently")
        check(store.isLive(MeasurementKey(0x10, 0), attempt: first, ready: true, at: 6, staleAfter: 5), "battery remains fresh")
        store.apply(try report([1, 5, 0, 0xC0, 0xBD, 0xF0, 0xFF]), attempt: first, at: 7)
        check(store.entries[pressureKey] == nil, "missing sentinel clears field")
        store.apply(pressure, attempt: first, at: 8)
        let partial = try report([2, 5, 0, 200, 0, 0, 0, 0xFF, 0])
        store.apply(partial, attempt: first, at: 9)
        check(store.entries[pressureKey]?.observedAt == 8, "partial report never refreshes")
        store.invalidate()
        check(!store.isLive(pressureKey, attempt: first, ready: true, at: 9, staleAfter: 5), "disconnect invalidates")
        _ = session.disconnected(first, at: 10)
        guard case .connect(let second) = session.launch(at: 11) else { fatalError("next token") }
        check(!store.isLive(pressureKey, attempt: second, ready: true, at: 11, staleAfter: 5), "generation isolation")
        store.apply(pressure, attempt: second, at: 12)
        check(store.isLive(pressureKey, attempt: second, ready: true, at: 12, staleAfter: 5), "new field restores itself")
        check(!store.isLive(MeasurementKey(0x10, 0), attempt: second, ready: true, at: 12, staleAfter: 5), "old battery remains stale")
        store.removeTemperatures()
        store.apply(try report([1, 2, 0, 200, 0]), attempt: second, at: 13)
        guard case .number(let number) = store.entries[MeasurementKey(2, 0)]?.field.value else { fatalError("temperature") }
        check(number.unit == .unknown, "never guess Celsius")
        store.removeTemperatures()
        check(store.entries[MeasurementKey(2, 0)] == nil, "unit context change discards retained temperatures")
        check(RetryPolicy.delay(afterFailures: 1) == 2, "first retry delay")
        check(RetryPolicy.delay(afterFailures: 3) == 8, "bounded backoff")
        check(RetryPolicy.delay(afterFailures: 4) == nil, "retry budget exhausted")
        print("PASS: profile/auth allowlist, independent field freshness, missing/partial handling, generation isolation, unknown units, bounded retries")
    }
}
