import Foundation
import SwiftUI
import GaugeglassCore

@main
@MainActor
struct GaugeglassApp: App {
    @StateObject private var instrument = InstrumentModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            InstrumentPanel(model: instrument)
                .preferredColorScheme(.dark)
                .onAppear { instrument.setActive(scenePhase == .active) }
                .onChange(of: scenePhase) { phase in instrument.setActive(phase == .active) }
        }
    }
}

@MainActor
struct InstrumentPanel: View {
    @ObservedObject var model: InstrumentModel

    private var keys: [MeasurementKey] {
        let primary: [UInt8]
        switch model.saved?.category {
        case 0, 1: primary = [2, 3, 1]
        case 3, 5: primary = [9, 1]
        case 9: primary = [4, 1]
        case 10: primary = [4, 0x0B, 1]
        case 29, 34, 35: primary = [5, 6, 2, 3, 9, 0x10]
        default: primary = [5, 6, 2, 3, 9, 1]
        }
        let defaults = primary.map { MeasurementKey($0, 0) }
        return defaults + model.fields.entries.keys.filter { !defaults.contains($0) }.sorted { $0.hex < $1.hex }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.saved?.name ?? "No instrument selected").font(.title2.bold())
                        Label(model.status, systemImage: model.ready ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(model.ready ? Color.green : Color.orange)
                        Text(model.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        ForEach(keys, id: \.self) { key in
                            ReadingTile(key: key, entry: model.fields.entries[key], live: model.isLive(key), now: model.now)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Temperature decode context").font(.headline)
                        Picker("Match the unit set on your gauge", selection: $model.temperatureChoice) {
                            Text("Unknown").tag(0)
                            Text("°C").tag(1)
                            Text("°F").tag(2)
                        }.pickerStyle(.segmented)
                        Text("Local interpretation only — does not change your gauge. Choose only if you know the gauge's current setting. Unknown shows an unlabeled scale. Changing this selection discards old temperatures and waits for new reports.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Source-derived · hardware unverified", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(.orange)
                        Text("Compare against the instrument display before relying on readings. Vacuum Pa scaling is provisional. Connection/authentication, advertisement identity, packet boundaries and units have not been verified on equipment.")
                            .font(.footnote)
                        Button("Valve controls unavailable") {}.disabled(true)
                        Text("Readings and authentication only. No settings, refrigerant, calibration, OTA, valve or pump actuation commands are implemented.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Choose instrument") { model.openPicker() }.buttonStyle(.bordered)
                        Button("Retry") { model.retry() }.buttonStyle(.borderedProminent)
                    }
                }.padding()
            }
            .navigationTitle("Gaugeglass")
            .sheet(isPresented: $model.showingPicker, onDismiss: { model.closePicker() }) {
                DevicePicker(model: model)
            }
        }
    }
}

private struct ReadingTile: View {
    let key: MeasurementKey
    let entry: FieldEntry?
    let live: Bool
    let now: Double

    private var title: String {
        switch key.hex {
        case "0100": return "Battery"
        case "1000": return "Main battery"
        case "1100": return "Low probe battery"
        case "1200": return "High probe battery"
        case "1300": return "Vacuum probe battery"
        case "0200": return "Low temperature"
        case "0300": return "High temperature"
        case "0400": return "Temperature"
        case "0500": return "Low pressure"
        case "0600": return "High pressure"
        case "0900": return "Vacuum"
        case "0B00": return "Humidity"
        case "1800": return "Auxiliary high pressure"
        case "1900": return "Auxiliary low pressure"
        default: return "Field \(key.hex)"
        }
    }
    private var number: MeasurementNumber? {
        if let entry, case .number(let number) = entry.field.value { return number }
        return nil
    }
    private var unit: String {
        switch number?.unit {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        case .pascal: return "Pa"
        case .percentBattery: return "% battery"
        case .percentRelativeHumidity: return "% RH"
        default: return ""
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(number.map { $0.value.formatted(.number.precision(.fractionLength(0...1))) } ?? "—")
                .font(.system(.largeTitle, design: .monospaced).bold())
                .minimumScaleFactor(0.45).lineLimit(1)
                .foregroundStyle(live ? Color.white : Color.secondary)
            if !unit.isEmpty { Text(unit).font(.caption) }
            if let number, number.unit == .unknown {
                Text("Unlabeled scale · unit unknown").font(.caption).foregroundStyle(.orange)
            }
            if let number, number.scaleConfidence == .provisional {
                Text("Provisional Pa scale").font(.caption).foregroundStyle(.orange)
            }
            if let number, number.normalization != .none {
                Text(number.normalization == .batteryFFMappedToZero ? "Source ff → 0; battery not confirmed" : "Source-clamped battery value")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let entry {
                Text("\(live ? "LIVE" : "STALE") · \(Int(max(0, now - entry.observedAt)))s ago")
                    .font(.caption.bold()).foregroundStyle(live ? Color.green : Color.orange)
            } else {
                Text("No valid reading").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct DevicePicker: View {
    @ObservedObject var model: InstrumentModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose your own instrument explicitly. A Bluetooth name/service is not authenticated identity; confirm the physical label. Only source-known shared-decoder profiles appear.")
                        .font(.footnote)
                    Text(model.detail).font(.footnote).foregroundStyle(.secondary)
                    if model.scanning { ProgressView("Scanning — bounded 15-second window") }
                    Button("Scan again") { model.retry() }
                }
                Section("Compatible advertisements") {
                    if model.candidates.isEmpty { Text("No compatible advertisements found.").foregroundStyle(.secondary) }
                    ForEach(model.candidates, id: \.id) { device in
                        Button { model.choose(device) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name).font(.headline)
                                Text("Category \(device.category) · \(device.id.uuidString)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choose instrument")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.showingPicker = false } } }
        }
    }
}
