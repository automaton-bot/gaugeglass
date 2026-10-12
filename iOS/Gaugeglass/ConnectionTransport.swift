import Foundation
import CoreBluetooth
import GaugeglassCore

/// Exact Bluetooth-base UUIDs; source's substring matching is deliberately NOT used.
/// Full GATT identity and properties still need hardware verification.
@MainActor
enum GaugeGATT {
    static let service = CBUUID(string: "0000FE60-0000-1000-8000-00805F9B34FB")
    static let write = CBUUID(string: "0000FE61-0000-1000-8000-00805F9B34FB")
    static let notify = CBUUID(string: "0000FE62-0000-1000-8000-00805F9B34FB")
}

/// Each attempt owns a fresh CENTRAL and delegate proxy with an immutable token.
/// Never replace a peripheral delegate while a prior attempt is cancelling. CoreBluetooth
/// can reuse CBPeripheral objects; this extra isolation plus terminal-callback barrier avoids
/// attributing delayed central events to the current session's generation.
@MainActor
final class ConnectionTransport: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    weak var owner: InstrumentModel?
    let device: SavedDevice
    let token: ConnectionAttempt
    private(set) var closing = false
    private(set) var hasSentChallengeReply = false
    private var hasAnsweredChallenge = false
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var connectionOutstanding = false
    private var attemptedLookup = false
    private var requestSent = false
    private var writeOutstanding = false
    private var queuedReply: Packet?
    private var terminal = false

    init(owner: InstrumentModel, device: SavedDevice, token: ConnectionAttempt) {
        self.owner = owner; self.device = device; self.token = token
        super.init()
    }
    func start() { central = CBCentralManager(delegate: self, queue: .main) }
    func cancel() {
        guard !terminal else { return }
        closing = true
        central.stopScan()
        queuedReply = nil // no command replay across reconnects
        if connectionOutstanding, let peripheral {
            central.cancelPeripheralConnection(peripheral)
            // Intentionally no timeout that releases this barrier. Missing terminal callback
            // blocks retries instead of overlapping a still-cancelling old transport.
        } else { finish(error: nil) }
    }
    private func finish(error: Error?) {
        guard !terminal else { return }
        terminal = true
        closing = true
        central.stopScan()
        central.delegate = nil
        peripheral?.delegate = nil
        queuedReply = nil
        owner?.finished(self, error: error)
    }
    private var usable: Bool { !terminal && !closing && owner?.accepts(self) == true }
    private func fail(_ reason: SessionFailure, _ message: String) {
        owner?.fail(self, reason: reason, message: message)
    }
    private func connect(_ candidate: CBPeripheral) {
        guard usable, !connectionOutstanding, candidate.identifier == device.id else { return }
        // Cached names may be absent. A known conflicting profile is rejected; a UUID is
        // persistence, not cryptographic identity. The initial user's selection remains necessary.
        if let name = candidate.name, DeviceProfile.match(name)?.rawValue != device.category {
            fail(.transport, "Saved peripheral now reports an unknown/different profile. Select the instrument again.")
            return
        }
        central.stopScan()
        peripheral = candidate
        candidate.delegate = self
        connectionOutstanding = true
        central.connect(candidate, options: nil)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !terminal, central === self.central else { return }
        if closing { return }
        switch central.state {
        case .poweredOn:
            guard usable, !attemptedLookup else { return }
            attemptedLookup = true
            if let known = central.retrievePeripherals(withIdentifiers: [device.id]).first {
                connect(known)
            } else {
                // Session phase timeout bounds this fallback scan. No nearest/name auto-selection.
                central.scanForPeripherals(withServices: [GaugeGATT.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        case .unknown: break // bounded by session phase timeout
        default: fail(.transport, "Bluetooth is unavailable (\(central.state.rawValue)); enable Bluetooth/permission.")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, usable, peripheral.identifier == device.id,
              let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
              DeviceProfile.match(name)?.rawValue == device.category else { return }
        connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral, !terminal else { return }
        if closing { central.cancelPeripheralConnection(peripheral); return }
        guard usable, owner?.connected(self) == true else { cancel(); return }
        peripheral.discoverServices([GaugeGATT.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        connectionOutstanding = false
        finish(error: error)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        connectionOutstanding = false
        finish(error: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard usable, peripheral === self.peripheral else { return }
        guard error == nil else { fail(.subscription, "Service discovery failed: \(error!.localizedDescription)"); return }
        let services = (peripheral.services ?? []).filter { $0.uuid == GaugeGATT.service }
        guard services.count == 1, let service = services.first else {
            fail(.subscription, "Expected exact FE60 Bluetooth-base service missing/ambiguous."); return
        }
        peripheral.discoverCharacteristics([GaugeGATT.notify, GaugeGATT.write], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard usable, peripheral === self.peripheral, service.uuid == GaugeGATT.service else { return }
        guard error == nil else { fail(.subscription, "Characteristic discovery failed: \(error!.localizedDescription)"); return }
        let reads = (service.characteristics ?? []).filter { $0.uuid == GaugeGATT.notify }
        let writes = (service.characteristics ?? []).filter { $0.uuid == GaugeGATT.write }
        guard reads.count == 1, writes.count == 1, let read = reads.first, let write = writes.first,
              (read.properties.contains(.notify) || read.properties.contains(.indicate)),
              write.properties.contains(.write) else {
            fail(.subscription, "FE62 notifications/indications and FE61 acknowledged writes are required; unsupported GATT properties.")
            return
        }
        guard notifyCharacteristic == nil else { return }
        notifyCharacteristic = read
        writeCharacteristic = write
        peripheral.setNotifyValue(true, for: read)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard usable, peripheral === self.peripheral, characteristic === notifyCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            fail(.subscription, "Measurement subscription failed or was lost."); return
        }
        guard !requestSent else { return }
        guard owner?.subscribed(self) == true else { cancel(); return }
        requestSent = true
        writeAuth(AuthOnly.request) // only AFTER successful FE62 subscription callback
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard usable, peripheral === self.peripheral, characteristic === notifyCharacteristic else { return }
        guard error == nil, let data = characteristic.value else {
            fail(.subscription, "Notification delivery failed or contained no data."); return
        }
        owner?.received(data, from: self)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard usable, peripheral === self.peripheral, characteristic === writeCharacteristic, writeOutstanding else { return }
        writeOutstanding = false
        if let error { fail(.transport, "Authentication write failed: \(error.localizedDescription)"); return }
        if let reply = queuedReply { queuedReply = nil; writeAuth(reply) }
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard usable, peripheral === self.peripheral else { return }
        if invalidatedServices.contains(where: { $0.uuid == GaugeGATT.service }) {
            fail(.subscription, "Instrument's measurement service was invalidated.")
        }
    }
    func answer(_ challenge: AuthenticationChallenge) {
        guard usable, requestSent, !hasAnsweredChallenge else {
            if usable { fail(.authenticationRejected, "Repeated/unexpected authentication challenge; cancelling safely.") }
            return
        }
        hasAnsweredChallenge = true
        if writeOutstanding { queuedReply = challenge.reply } else { writeAuth(challenge.reply) }
    }
    /// The ONLY BLE value-write site. It accepts only the fixed observed request or a core-
    /// generated challenge reply; settings/control/calibration/OTA/unit writes have no path.
    private func writeAuth(_ packet: Packet) {
        guard usable, owner?.session.phase == .authenticating, AuthOnly.permits(packet),
              !writeOutstanding, let peripheral, let characteristic = writeCharacteristic,
              peripheral.state == .connected,
              packet.bytes.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            if usable { fail(.transport, "Authentication write prerequisites not satisfied.") }
            return
        }
        writeOutstanding = true
        if packet != AuthOnly.request { hasSentChallengeReply = true }
        peripheral.writeValue(Data(packet.bytes), for: characteristic, type: .withResponse)
    }
}
