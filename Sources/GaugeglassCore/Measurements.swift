/// Category numbers are external source-app context, not inferred from wire fields.
/// These names do not certify hardware identity or compatibility.
public enum MeasurementFamily: Int, CaseIterable, Sendable {
    case lowTemperatureClamp = 0, highTemperatureClamp = 1, vacuumPump = 3
    case digitalManifold = 4, vacuumGauge = 5, fourValveManifold = 8
    case largeTemperatureClamp = 9, temperatureHumidity = 10
    case manifold29 = 29, manifold34 = 34, manifold35 = 35
}

public enum MeasurementTemperatureUnit: Equatable, Sendable { case unknown, celsius, fahrenheit }
public enum MeasurementUnit: Equatable, Sendable {
    case unknown, celsius, fahrenheit, pascal, percentBattery, percentRelativeHumidity
}
public enum MeasurementConfidence: Equatable, Sendable { case sourceDerivedHardwareUnverified }
public enum MeasurementScaleConfidence: Equatable, Sendable { case sourceDerived, provisional }
public enum MeasurementNormalization: Equatable, Sendable {
    case none, batteryClamped, batteryFFMappedToZero
}

public struct MeasurementContext: Equatable, Sendable {
    public let category: Int
    public let temperatureUnit: MeasurementTemperatureUnit
    public var family: MeasurementFamily? { MeasurementFamily(rawValue: category) }
    /// Unit context must come from known instrument configuration, not a guessed default.
    public init(category: Int, temperatureUnit: MeasurementTemperatureUnit = .unknown) {
        self.category = category
        self.temperatureUnit = temperatureUnit
    }
}

/// A literal ordered two-byte token, not a host-endian UInt16 identifier.
public struct MeasurementKey: Equatable, Hashable, Sendable {
    public let first: UInt8
    public let second: UInt8
    public init(_ first: UInt8, _ second: UInt8) { self.first = first; self.second = second }
    public var bytes: [UInt8] { [first, second] }
    public var hex: String { Hex.encode(bytes) }
}

public enum MeasurementSemantic: Equatable, Sendable {
    case battery, mainBattery, lowProbeBattery, highProbeBattery, vacuumProbeBattery
    case lowTemperature, highTemperature, temperature
    case lowPressure, highPressure, vacuum
    case humidity, auxiliaryHighTemperatureUnscaled, auxiliaryLowTemperatureUnscaled
    case auxiliaryHighPressure, auxiliaryLowPressure
    case opaque, chargingIndicatorUninterpreted
}

public struct MeasurementNumber: Equatable, Sendable {
    public let rawInteger: Int64
    /// A source-derived scale hint, not a hardware-certified physical reading.
    public let value: Double
    public let unit: MeasurementUnit
    public let scaleConfidence: MeasurementScaleConfidence
    public let normalization: MeasurementNormalization
}
public enum MeasurementValue: Equatable, Sendable {
    case number(MeasurementNumber)
    case missing(rawInteger: Int64)
    /// Meaning/scale is unresolved. Bytes remain in MeasurementField.rawValue.
    case opaque
}
public struct MeasurementField: Equatable, Sendable {
    public let key: MeasurementKey
    public let rawValue: [UInt8]
    public let semantic: MeasurementSemantic
    public let value: MeasurementValue
}

public enum MeasurementError: Error, Equatable, Sendable { case unexpectedCommand(UInt8) }
public enum MeasurementParseIssue: Equatable, Sendable {
    case missingFieldCount
    case unsupportedCategory(Int)
    case countMismatch(expected: Int, parsed: Int)
    case truncatedKey(fieldIndex: Int, available: Int)
    case unknownKey(MeasurementKey)
    case unsupportedKey(MeasurementKey, category: Int)
    case truncatedValue(MeasurementKey, expected: Int, available: Int)
    case trailingBytes(count: Int)
}

/// Parsed prefix is diagnostic only when issue != nil; it is not a complete update.
/// No receipt time is fabricated; attach adapter receipt time and connection identity externally.
public struct MeasurementReport: Equatable, Sendable {
    public let packet: Packet
    public let context: MeasurementContext
    public let declaredFieldCount: UInt8?
    public let fields: [MeasurementField]
    /// Begins at the first unconsumed key (including that key), or at trailing bytes.
    /// Unsupported categories retain the entire payload including count.
    public let unparsedRemainder: [UInt8]
    public let issue: MeasurementParseIssue?
    public var isComplete: Bool { issue == nil }
    public var confidence: MeasurementConfidence { .sourceDerivedHardwareUnverified }
}

/// Pure command-03 decoding. No BLE transport, authentication hooks, or writes.
public enum Measurements {
    private enum Encoding: Sendable {
        case battery(mapFFToZero: Bool), temperature, pressure, vacuum, humidity, opaque
    }
    private struct Rule: Sendable {
        let key: MeasurementKey
        let categories: [Int]
        let width: Int
        let semantic: MeasurementSemantic
        let encoding: Encoding
    }
    private static let manifolds = [4, 8, 29, 34, 35]
    private static let newerManifolds = [29, 34, 35]
    private static let supported = MeasurementFamily.allCases.map(\.rawValue)
    // Exact key/category widths only. No general key-prefix or unknown-key width rule.
    private static let rules: [Rule] = [
        Rule(key: MeasurementKey(1, 0), categories: supported, width: 1, semantic: .battery, encoding: .battery(mapFFToZero: false)),
        Rule(key: MeasurementKey(0x10, 0), categories: newerManifolds, width: 1, semantic: .mainBattery, encoding: .battery(mapFFToZero: true)),
        Rule(key: MeasurementKey(0x11, 0), categories: newerManifolds, width: 1, semantic: .lowProbeBattery, encoding: .battery(mapFFToZero: true)),
        Rule(key: MeasurementKey(0x12, 0), categories: newerManifolds, width: 1, semantic: .highProbeBattery, encoding: .battery(mapFFToZero: true)),
        Rule(key: MeasurementKey(0x13, 0), categories: newerManifolds, width: 1, semantic: .vacuumProbeBattery, encoding: .battery(mapFFToZero: true)),
        Rule(key: MeasurementKey(2, 0), categories: [0, 1] + manifolds, width: 2, semantic: .lowTemperature, encoding: .temperature),
        Rule(key: MeasurementKey(3, 0), categories: [0, 1] + manifolds, width: 2, semantic: .highTemperature, encoding: .temperature),
        Rule(key: MeasurementKey(4, 0), categories: [9, 10], width: 2, semantic: .temperature, encoding: .temperature),
        Rule(key: MeasurementKey(5, 0), categories: manifolds, width: 4, semantic: .lowPressure, encoding: .pressure),
        Rule(key: MeasurementKey(6, 0), categories: manifolds, width: 4, semantic: .highPressure, encoding: .pressure),
        Rule(key: MeasurementKey(9, 0), categories: [3, 5] + manifolds, width: 4, semantic: .vacuum, encoding: .vacuum),
        Rule(key: MeasurementKey(0x0B, 0), categories: [10], width: 2, semantic: .humidity, encoding: .humidity),
        Rule(key: MeasurementKey(0x0B, 0), categories: newerManifolds, width: 2, semantic: .auxiliaryHighTemperatureUnscaled, encoding: .opaque),
        Rule(key: MeasurementKey(0x0C, 0), categories: [10], width: 2, semantic: .opaque, encoding: .opaque),
        Rule(key: MeasurementKey(0x0C, 0), categories: newerManifolds, width: 2, semantic: .auxiliaryLowTemperatureUnscaled, encoding: .opaque),
        Rule(key: MeasurementKey(0x14, 0), categories: supported, width: 2, semantic: .opaque, encoding: .opaque),
        Rule(key: MeasurementKey(0x15, 0), categories: supported, width: 2, semantic: .opaque, encoding: .opaque),
        Rule(key: MeasurementKey(0x16, 0), categories: supported, width: 2, semantic: .opaque, encoding: .opaque),
        Rule(key: MeasurementKey(0x17, 0), categories: newerManifolds, width: 1, semantic: .chargingIndicatorUninterpreted, encoding: .opaque),
        Rule(key: MeasurementKey(0x18, 0), categories: newerManifolds, width: 4, semantic: .auxiliaryHighPressure, encoding: .pressure),
        Rule(key: MeasurementKey(0x19, 0), categories: newerManifolds, width: 4, semantic: .auxiliaryLowPressure, encoding: .pressure)
    ]
    // Catalog presence distinguishes unsupported from unknown; it NEVER supplies a width.
    private static let knownKeys: Set<MeasurementKey> = Set(
        [UInt8(1), 2, 3, 4, 5, 6, 7, 8, 9, 0x0A, 0x0B, 0x0C,
         0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19].map { MeasurementKey($0, 0) }
        + [MeasurementKey(0, 1), MeasurementKey(0, 8)])

    /// Requires a checksum-valid, externally delimited command-03 Packet.
    /// Incomplete results retain a diagnostic prefix and remainder, never silently succeed.
    public static func decode(_ packet: Packet, context: MeasurementContext) throws -> MeasurementReport {
        guard packet.isChecksumValid else {
            throw PacketError.checksumMismatch(expected: packet.expectedChecksum, actual: packet.checksum)
        }
        guard packet.command == 3 else { throw MeasurementError.unexpectedCommand(packet.command) }
        let payload = packet.payload
        var fields: [MeasurementField] = []
        var cursor = 0
        func report(_ issue: MeasurementParseIssue?) -> MeasurementReport {
            MeasurementReport(packet: packet, context: context, declaredFieldCount: payload.first,
                              fields: fields, unparsedRemainder: Array(payload.dropFirst(cursor)), issue: issue)
        }
        guard context.family != nil else { return report(.unsupportedCategory(context.category)) }
        guard let count = payload.first else { return report(.missingFieldCount) }
        cursor = 1
        for index in 0..<Int(count) {
            let available = payload.count - cursor
            guard available > 0 else { return report(.countMismatch(expected: Int(count), parsed: fields.count)) }
            guard available >= 2 else { return report(.truncatedKey(fieldIndex: index, available: available)) }
            let key = MeasurementKey(payload[cursor], payload[cursor + 1])
            guard let rule = rules.first(where: { $0.key == key && $0.categories.contains(context.category) }) else {
                return report(knownKeys.contains(key) ? .unsupportedKey(key, category: context.category) : .unknownKey(key))
            }
            guard available - 2 >= rule.width else {
                return report(.truncatedValue(key, expected: rule.width, available: available - 2))
            }
            let raw = Array(payload[(cursor + 2)..<(cursor + 2 + rule.width)])
            fields.append(MeasurementField(key: key, rawValue: raw, semantic: rule.semantic,
                                           value: interpret(raw, rule: rule, context: context)))
            cursor += 2 + rule.width
        }
        if cursor < payload.count { return report(.trailingBytes(count: payload.count - cursor)) }
        return report(nil)
    }

    /// Conventional source-intended two's complement, not the defective app minimum-value helper.
    /// Every calling rule has an explicit width (at most four bytes), verified before slicing.
    private static func integer(_ bytes: [UInt8], signed: Bool) -> Int64 {
        let unsigned = bytes.enumerated().reduce(Int64(0)) { $0 | (Int64($1.element) << ($1.offset * 8)) }
        let bits = bytes.count * 8
        return signed && unsigned & (Int64(1) << (bits - 1)) != 0 ? unsigned - (Int64(1) << bits) : unsigned
    }

    private static func interpret(_ bytes: [UInt8], rule: Rule, context: MeasurementContext) -> MeasurementValue {
        func number(_ raw: Int64, value: Double, unit: MeasurementUnit,
                    confidence: MeasurementScaleConfidence = .sourceDerived,
                    normalization: MeasurementNormalization = .none) -> MeasurementValue {
            .number(MeasurementNumber(rawInteger: raw, value: value, unit: unit,
                                      scaleConfidence: confidence, normalization: normalization))
        }
        switch rule.encoding {
        case .opaque: return .opaque
        case .battery(let mapFF):
            let raw = Int64(bytes[0])
            if mapFF && bytes[0] == 0xFF {
                return number(raw, value: 0, unit: .percentBattery, normalization: .batteryFFMappedToZero)
            }
            return number(raw, value: Double(min(raw, 100)), unit: .percentBattery,
                          normalization: raw > 100 ? .batteryClamped : .none)
        case .temperature:
            let raw = integer(bytes, signed: true)
            if manifolds.contains(context.category) && raw == -9999 { return .missing(rawInteger: raw) }
            let unit: MeasurementUnit
            switch context.temperatureUnit {
            case .unknown: unit = .unknown
            case .celsius: unit = .celsius
            case .fahrenheit: unit = .fahrenheit
            }
            return number(raw, value: Double(raw) / 10, unit: unit)
        case .pressure:
            let raw = integer(bytes, signed: true)
            let auxiliary = rule.semantic == .auxiliaryHighPressure || rule.semantic == .auxiliaryLowPressure
            if raw == (auxiliary ? -1061293825 : -1000000) { return .missing(rawInteger: raw) }
            return number(raw, value: Double(raw), unit: .pascal)
        case .vacuum:
            let raw = integer(bytes, signed: true)
            if manifolds.contains(context.category) && raw == -1 { return .missing(rawInteger: raw) }
            return number(raw, value: Double(raw) / 100, unit: .pascal, confidence: .provisional)
        case .humidity:
            let raw = integer(bytes, signed: false)
            return number(raw, value: Double(raw) / 10, unit: .percentRelativeHumidity)
        }
    }
}
