import Foundation
import SwiftUI
import CoreBluetooth
import GaugeglassCore

/// All BLE delegates run synchronously on the explicitly configured main queue.
/// @preconcurrency bridges the SDK's nonisolated delegate requirements; no Task hops
/// can reorder a terminal callback behind a new connection attempt.
@MainActor
final class InstrumentModel: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    @Published private(set) var session: SessionState
    @Published private(set) var fields = FieldStore()
    @Published private(set) var saved: SavedDevice?
    @Published private(set) var candidates: [SavedDevice] = []
    @Published private(set) var detail = "Select your instrument once to begin."
    @Published private(set) var now = ProcessInfo.processInfo.systemUptime
    @Published private(set) var scanning = false
    @Published var showingPicker = false
    @Published var temperatureChoice = 0 {
        didSet { fields.removeTemperatures() } // Never relabel old samples or write gauge settings.
    }
    private var discovery: CBCentralManager?
    private var transport: ConnectionTransport?
    private var timer: Timer?
    private var active = false
    private var pickerMode = false
    private var scanEndsAt: Double?
    private var retryAt: Double?
    private var failures = 0
    private var pendingSelection: SavedDevice?
    private let storageKey = "gaugeglass.savedPeripheral.v1"

    override init() {
        let key = "gaugeglass.savedPeripheral.v1"
        let decoded = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(SavedDevice.self, from: $0) }
        let device = decoded.flatMap { $0.isSupported ? $0 : nil }
        saved = device
        // Fixed app-policy constants, not a claim about equipment cadence.
        let configuration = try! SessionConfiguration(staleAfter: 5, phaseTimeout: 20, requiresAuthentication: true)
        session = try! SessionState(savedDeviceID: device?.id.uuidString, configuration: configuration)
        super.init()
    }

    var ready: Bool { active && session.phase == .ready }
    var temperatureUnit: MeasurementTemperatureUnit {
        switch temperatureChoice { case 1: return .celsius; case 2: return .fahrenheit; default: return .unknown }
    }
    var status: String {
        if transport?.closing == true { return "Waiting for Bluetooth cancellation" }
        if !active { return "Paused — readings stale" }
        if scanning { return "Looking for compatible instruments" }
        switch session.phase {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting to saved instrument"
        case .subscribing: return "Subscribing to readings"
        case .authenticating: return "Authenticating (source-derived)"
        case .ready: return "Connected — check each reading's age"
        case .error(let error): return "Connection error: \(error)"
        }
    }
    func isLive(_ key: MeasurementKey) -> Bool {
        fields.isLive(key, attempt: session.attempt, ready: ready, at: now,
                      staleAfter: session.configuration.staleAfter)
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        now = ProcessInfo.processInfo.systemUptime
        session.tick(at: now)
        if value {
            failures = 0
            retryAt = nil
            let foregroundTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // Keep freshness and phase/scan deadlines advancing during UI tracking.
            RunLoop.main.add(foregroundTimer, forMode: .common)
            timer = foregroundTimer
            if saved == nil { pickerMode = true; showingPicker = true }
            if pickerMode { startPickerScan() } else { reconnect() }
        } else {
            timer?.invalidate(); timer = nil
            stopPickerScan()
            retryAt = nil
            fields.invalidate()
            if let transport {
                _ = session.disconnected(transport.token, at: now)
                transport.cancel()
            }
        }
    }

    func openPicker() {
        pickerMode = true
        showingPicker = true
        pendingSelection = nil
        retryAt = nil
        stopPickerScan()
        candidates.removeAll()
        fields.invalidate()
        if let transport {
            _ = session.disconnected(transport.token, at: uptime())
            transport.cancel()
        }
        startPickerScan()
    }
    func closePicker() {
        stopPickerScan()
        showingPicker = false
        pickerMode = false
        failures = 0
        retryAt = nil
        reconnect()
    }
    func choose(_ device: SavedDevice) {
        guard active, candidates.contains(device), device.isSupported else { return }
        stopPickerScan()
        showingPicker = false
        pickerMode = false
        pendingSelection = device
        failures = 0
        retryAt = nil
        fields.invalidate()
        if let transport {
            _ = session.disconnected(transport.token, at: uptime())
            transport.cancel()
        } else { consumeSelection() }
    }
    func retry() {
        guard active else { return }
        failures = 0; retryAt = nil
        if let transport, transport.closing {
            detail = "Cancellation must finish before retrying. If Bluetooth never delivers a terminal callback, relaunch the app."
            return
        }
        if saved == nil { openPicker() }
        else if pickerMode { startPickerScan() }
        else { reconnect() }
    }

    private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
    private func tick() {
        guard active else { return }
        now = uptime()
        session.tick(at: now)
        if case .error = session.phase, let transport, !transport.closing {
            fields.invalidate()
            detail = "Connection phase timed out; cancelling before any retry."
            transport.cancel()
        }
        if let end = scanEndsAt, now >= end {
            stopPickerScan()
            detail = "Discovery window ended. Scan again or turn on your instrument."
        }
        if let retry = retryAt, now >= retry, transport == nil {
            retryAt = nil
            reconnect()
        }
    }
    private func consumeSelection() {
        guard transport == nil, let device = pendingSelection else { return }
        pendingSelection = nil
        saved = device
        temperatureChoice = 0
        fields.clear()
        if let data = try? JSONEncoder().encode(device) { UserDefaults.standard.set(data, forKey: storageKey) }
        let action = session.selectDevice(device.id.uuidString, supported: device.isSupported, at: uptime())
        begin(action, device: device)
    }
    private func reconnect() {
        guard active, !pickerMode, transport == nil else { return }
        if pendingSelection != nil { consumeSelection(); return }
        guard let saved, saved.isSupported else { return }
        begin(session.launch(at: uptime()), device: saved)
    }
    private func begin(_ action: SessionAction, device: SavedDevice) {
        guard active, transport == nil, case .connect(let token) = action else { return }
        fields.invalidate()
        detail = "Retrieving saved UUID; fallback discovery can match only that same UUID."
        let connection = ConnectionTransport(owner: self, device: device, token: token)
        transport = connection
        connection.start()
    }
    private func startPickerScan() {
        guard active, pickerMode else { return }
        if discovery == nil {
            discovery = CBCentralManager(delegate: self, queue: .main)
        }
        guard discovery?.state == .poweredOn else { return }
        discovery?.scanForPeripherals(withServices: [GaugeGATT.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true
        scanEndsAt = uptime() + 15
        detail = "Names/services can be spoofed. Select only your own instrument; confirm its physical label and readings."
    }
    private func stopPickerScan() {
        discovery?.stopScan()
        scanning = false; scanEndsAt = nil
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === discovery else { return }
        if central.state == .poweredOn { startPickerScan() }
        else {
            stopPickerScan()
            detail = "Bluetooth unavailable (\(central.state.rawValue)). Enable Bluetooth and allow access in Settings."
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === discovery, active, pickerMode, scanning,
              let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
              let family = DeviceProfile.match(name) else { return }
        let device = SavedDevice(id: peripheral.identifier, name: name, category: family.rawValue)
        candidates.removeAll { $0.id == device.id }
        candidates.append(device)
        candidates.sort { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
    }

    // Every call carries the transport's IMMUTABLE attempt token, never session.attempt.
    func accepts(_ source: ConnectionTransport) -> Bool {
        active && transport === source && !source.closing && session.attempt == source.token
    }
    func connected(_ source: ConnectionTransport) -> Bool {
        guard accepts(source) else { return false }
        return session.connected(source.token, at: uptime())
    }
    func subscribed(_ source: ConnectionTransport) -> Bool {
        guard accepts(source) else { return false }
        return session.subscribed(source.token, at: uptime())
    }
    func received(_ data: Data, from source: ConnectionTransport) {
        guard accepts(source) else { return }
        let receivedAt = uptime()
        now = receivedAt
        do {
            let packet = try Packet.decode(Array(data)) // strict checksum, one callback = one frame
            switch packet.command {
            case 1:
                guard session.phase == .authenticating else { return }
                switch try Authentication.decode(packet) {
                case .challenge(let challenge): source.answer(challenge)
                case .status(.accepted):
                    guard source.hasSentChallengeReply else {
                        fail(source, reason: .authenticationRejected, message: "Unexpected authentication acceptance before challenge response.")
                        return
                    }
                    if session.authenticated(source.token, at: receivedAt) {
                        detail = "Authenticated; waiting for complete checksum-valid measurement reports."
                    }
                case .status(.rejected): fail(source, reason: .authenticationRejected, message: "Instrument rejected authentication.")
                }
            case 3:
                guard session.phase == .ready else { return }
                let report = try Measurements.decode(packet, context: MeasurementContext(category: source.device.category,
                                                                                         temperatureUnit: temperatureUnit))
                guard report.isComplete else {
                    reject(source, message: "Incomplete/unsupported measurement discarded: \(String(describing: report.issue)).")
                    return
                }
                // Snapshot contains ONLY numbers in this report, not retained field values.
                let numbers = report.fields.reduce(into: [String: Double]()) { values, field in
                    if case .number(let number) = field.value { values[field.key.hex] = number.value }
                }
                if !numbers.isEmpty {
                    let snapshot = try SessionSnapshot(values: numbers)
                    guard session.receive(snapshot, from: source.token, observedAt: receivedAt, at: receivedAt) else { return }
                }
                fields.apply(report, attempt: source.token, at: receivedAt)
                detail = "Source-derived readings — hardware/physical units not verified."
            default: break // settings, state, ack, long data are NEVER measurements
            }
        } catch {
            // Checksum-invalid command-03 invalidates readings, not unrelated traffic.
            if data.count > 2, data[data.startIndex + 2] == 3 {
                reject(source, message: "Invalid measurement frame discarded: \(error)")
            } else if data.count > 2, data[data.startIndex + 2] == 1, session.phase == .authenticating {
                fail(source, reason: .authenticationRejected, message: "Invalid authentication frame: \(error)")
            } else { detail = "Unrecognized notification discarded; no reading refreshed." }
        }
    }
    private func reject(_ source: ConnectionTransport, message: String) {
        _ = session.rejectReading(from: source.token, at: uptime())
        fields.invalidate()
        detail = message
    }
    func fail(_ source: ConnectionTransport, reason: SessionFailure, message: String) {
        guard transport === source, !source.closing else { return }
        _ = session.failed(source.token, reason: reason, at: uptime())
        fields.invalidate(); detail = message
        source.cancel()
    }
    func finished(_ source: ConnectionTransport, error: Error?) {
        guard transport === source else { return }
        if session.phase != .disconnected {
            _ = session.failed(source.token, reason: .transport, at: uptime())
        }
        fields.invalidate()
        transport = nil
        if let error { detail = "Bluetooth ended: \(error.localizedDescription)" }
        guard active else { return }
        if pendingSelection != nil { consumeSelection(); return }
        guard !pickerMode else { return }
        failures += 1
        if let delay = RetryPolicy.delay(afterFailures: failures) {
            retryAt = uptime() + delay
            detail += " Retrying in \(Int(delay))s."
        } else {
            retryAt = nil
            detail += " Automatic retry budget exhausted. Tap Retry to start another bounded attempt."
        }
    }
}
