import XCTest
@testable import GaugeglassCore

// GENERATED, source-derived fixtures, never captured equipment traffic.
final class MeasurementTests: XCTestCase {
    private func frame(_ payload: [UInt8], command: UInt8 = 3) -> Packet {
        Packet(handle: 1, rawLength: 0xFE, command: command, payload: payload)
    }
    private func decode(_ payload: [UInt8], category: Int = 29,
                        unit: MeasurementTemperatureUnit = .unknown) throws -> MeasurementReport {
        try Measurements.decode(frame(payload), context: MeasurementContext(category: category, temperatureUnit: unit))
    }
    private func number(_ field: MeasurementField, file: StaticString = #filePath, line: UInt = #line) throws -> MeasurementNumber {
        guard case .number(let n) = field.value else {
            XCTFail("Expected numeric value", file: file, line: line)
            throw MeasurementError.unexpectedCommand(0)
        }
        return n
    }
    func testManifoldPressureTemperatureAndContext() throws {
        for category in [4, 8, 29, 34, 35] {
            let report = try decode([2, 5, 0, 0x78, 0x56, 0x34, 0x12, 2, 0, 0x85, 0xFF], category: category, unit: .celsius)
            XCTAssertTrue(report.isComplete)
            XCTAssertEqual(report.packet.command, 3)
            XCTAssertEqual(report.packet.rawLength, 0xFE) // No invented length validation.
            XCTAssertEqual(report.context.category, category)
            XCTAssertEqual(report.confidence, .sourceDerivedHardwareUnverified)
            XCTAssertEqual(report.declaredFieldCount, 2)
            XCTAssertEqual(report.fields.map(\.semantic), [.lowPressure, .lowTemperature])
            XCTAssertEqual(report.fields[0].key.bytes, [5, 0])
            XCTAssertEqual(report.fields[0].rawValue, [0x78, 0x56, 0x34, 0x12])
            let p = try number(report.fields[0])
            XCTAssertEqual(p.rawInteger, 0x12345678)
            XCTAssertEqual(p.unit, .pascal)
            XCTAssertEqual(p.scaleConfidence, .sourceDerived)
            let t = try number(report.fields[1])
            XCTAssertEqual(t.rawInteger, -123)
            XCTAssertEqual(t.value, -12.3)
            XCTAssertEqual(t.unit, .celsius)
        }
    }
    func testTemperatureRequiresExplicitConfiguredUnit() throws {
        for (configured, expected): (MeasurementTemperatureUnit, MeasurementUnit) in [(.unknown, .unknown), (.celsius, .celsius), (.fahrenheit, .fahrenheit)] {
            let n = try number(decode([1, 2, 0, 250, 0], unit: configured).fields[0])
            XCTAssertEqual(n.value, 25)
            XCTAssertEqual(n.unit, expected)
        }
    }
    func testSignedMinMaxAndNegativeOne() throws {
        for (bytes, expected): ([UInt8], Int64) in [([0, 0x80], -32768), ([0xFF, 0x7F], 32767), ([0xFF, 0xFF], -1)] {
            XCTAssertEqual(try number(decode([1, 2, 0] + bytes).fields[0]).rawInteger, expected)
        }
        for (bytes, expected): ([UInt8], Int64) in [([0, 0, 0, 0x80], -2147483648), ([0xFF, 0xFF, 0xFF, 0x7F], 2147483647), ([0xFF, 0xFF, 0xFF, 0xFF], -1)] {
            XCTAssertEqual(try number(decode([1, 5, 0] + bytes).fields[0]).rawInteger, expected)
        }
    }
    func testManifoldSentinels() throws {
        for category in [4, 8, 29, 34, 35] {
            let fields = try decode([3, 2, 0, 0xF1, 0xD8, 5, 0, 0xC0, 0xBD, 0xF0, 0xFF, 9, 0, 0xFF, 0xFF, 0xFF, 0xFF], category: category).fields
            XCTAssertEqual(fields.map(\.value), [.missing(rawInteger: -9999), .missing(rawInteger: -1000000), .missing(rawInteger: -1)])
        }
        XCTAssertEqual(try number(decode([1, 2, 0, 0xF1, 0xD8], category: 0).fields[0]).rawInteger, -9999)
        for category in [3, 5] {
            XCTAssertEqual(try number(decode([1, 9, 0, 0xFF, 0xFF, 0xFF, 0xFF], category: category).fields[0]).rawInteger, -1)
        }
    }
    func testVacuumScaleIsExplicitlyProvisional() throws {
        for category in [3, 5, 4, 8, 29, 34, 35] {
            let n = try number(decode([1, 9, 0, 0xD2, 4, 0, 0], category: category).fields[0])
            XCTAssertEqual(n.rawInteger, 1234)
            XCTAssertEqual(n.value, 12.34)
            XCTAssertEqual(n.unit, .pascal)
            XCTAssertEqual(n.scaleConfidence, .provisional)
        }
    }
    func testBatteryFFVariesByWireKeyAndFamily() throws {
        for category in [0, 1, 3, 4, 5, 8, 9, 10, 29, 34, 35] {
            let n = try number(decode([1, 1, 0, 0xFF], category: category).fields[0])
            XCTAssertEqual(n.rawInteger, 255)
            XCTAssertEqual(n.value, 100)
            XCTAssertEqual(n.normalization, .batteryClamped)
        }
        for category in [29, 34, 35] {
            for key: UInt8 in [0x10, 0x11, 0x12, 0x13] {
                let n = try number(decode([1, key, 0, 0xFF], category: category).fields[0])
                XCTAssertEqual(n.value, 0)
                XCTAssertEqual(n.normalization, .batteryFFMappedToZero)
                XCTAssertEqual(n.rawInteger, 255)
            }
        }
        let stopped = try decode([1, 0x10, 0, 0xFF], category: 4)
        XCTAssertEqual(stopped.issue, .unsupportedKey(MeasurementKey(0x10, 0), category: 4))
        XCTAssertEqual(stopped.unparsedRemainder, [0x10, 0, 0xFF])
    }
    func testOptionalBatteryAbsentAndOrdinaryBatteryClamping() throws {
        XCTAssertEqual(try decode([1, 5, 0, 0, 0, 0, 0]).fields.count, 1)
        for (raw, expected): (UInt8, Double) in [(0, 0), (77, 77), (101, 100)] {
            XCTAssertEqual(try number(decode([1, 0x10, 0, raw]).fields[0]).value, expected)
        }
    }
    func testUnknownKeyStopsWithoutDroppingParsedPrefix() throws {
        let r = try decode([3, 1, 0, 80, 0xAB, 0xCD, 1, 2, 5, 0, 0, 0, 0, 0])
        XCTAssertEqual(r.fields.count, 1)
        XCTAssertEqual(r.issue, .unknownKey(MeasurementKey(0xAB, 0xCD)))
        XCTAssertEqual(r.unparsedRemainder, [0xAB, 0xCD, 1, 2, 5, 0, 0, 0, 0, 0])
        XCTAssertFalse(r.isComplete)
    }
    func testKnownButUnsupportedKeyDoesNotGuessWidth() throws {
        let r = try decode([1, 8, 0, 1, 2, 3])
        XCTAssertEqual(r.issue, .unsupportedKey(MeasurementKey(8, 0), category: 29))
        XCTAssertEqual(r.unparsedRemainder, [8, 0, 1, 2, 3])
    }
    func testUnsupportedFamiliesNeverApplySharedCatalog() throws {
        for category in [11, 36, 2, 7, 14, 15, 30, 999, -1] {
            let r = try decode([1, 7, 0, 1, 2, 3, 4], category: category)
            XCTAssertEqual(r.issue, .unsupportedCategory(category))
            XCTAssertEqual(r.unparsedRemainder, [1, 7, 0, 1, 2, 3, 4])
            XCTAssertTrue(r.fields.isEmpty)
        }
    }
    func testMissingAndZeroCounts() throws {
        XCTAssertEqual(try decode([]).issue, .missingFieldCount)
        XCTAssertTrue(try decode([0]).isComplete)
        let extra = try decode([0, 0xAA])
        XCTAssertEqual(extra.issue, .trailingBytes(count: 1))
        XCTAssertEqual(extra.unparsedRemainder, [0xAA])
    }
    func testCountMismatchAndPartialKey() throws {
        let short = try decode([2, 1, 0, 80])
        XCTAssertEqual(short.issue, .countMismatch(expected: 2, parsed: 1))
        XCTAssertEqual(short.fields.count, 1)
        let partial = try decode([1, 5])
        XCTAssertEqual(partial.issue, .truncatedKey(fieldIndex: 0, available: 1))
        XCTAssertEqual(partial.unparsedRemainder, [5])
    }
    func testEveryPartialValueRetainsKeyAndBytes() throws {
        for (key, width): (UInt8, Int) in [(1, 1), (2, 2), (5, 4)] {
            for count in 0..<width {
                let suffix: [UInt8] = [key, 0] + Array(repeating: 0xAA, count: count)
                let r = try decode([1] + suffix)
                XCTAssertEqual(r.issue, .truncatedValue(MeasurementKey(key, 0), expected: width, available: count))
                XCTAssertEqual(r.unparsedRemainder, suffix)
                XCTAssertTrue(r.fields.isEmpty)
            }
        }
    }
    func testTrailingBytesAndDuplicateKeysPreserved() throws {
        let r = try decode([2, 1, 0, 10, 1, 0, 20, 0xDD, 0xEE])
        XCTAssertEqual(r.fields.count, 2)
        XCTAssertEqual(r.fields.map(\.rawValue), [[10], [20]])
        XCTAssertEqual(r.issue, .trailingBytes(count: 2))
        XCTAssertEqual(r.unparsedRemainder, [0xDD, 0xEE])
    }
    func testMaximumFieldCountIsBounded() throws {
        let r = try decode([255] + Array(repeating: [UInt8(1), 0, 10], count: 255).flatMap { $0 })
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.fields.count, 255)
        XCTAssertEqual(try decode([255]).issue, .countMismatch(expected: 255, parsed: 0))
    }
    func testOpaqueAndAuxiliaryFieldsAreNotInventedReadings() throws {
        let r = try decode([6, 0x14, 0, 0xFF, 0x80, 0x15, 0, 1, 2, 0x16, 0, 3, 4, 0x17, 0, 0xAA, 0x0B, 0, 0x34, 0x12, 0x0C, 0, 0xFF, 0xFF])
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.fields.map(\.value), Array(repeating: .opaque, count: 6))
        XCTAssertEqual(r.fields.map(\.rawValue), [[0xFF, 0x80], [1, 2], [3, 4], [0xAA], [0x34, 0x12], [0xFF, 0xFF]])
        XCTAssertEqual(r.fields[4].semantic, .auxiliaryHighTemperatureUnscaled)
        XCTAssertEqual(r.fields[5].semantic, .auxiliaryLowTemperatureUnscaled)
    }
    func testHumidityAndGenericTemperatureHaveNarrowFamilies() throws {
        let r = try decode([2, 4, 0, 0xFA, 0, 0x0B, 0, 0x2B, 2], category: 10)
        XCTAssertEqual(try number(r.fields[1]).value, 55.5)
        XCTAssertEqual(try number(r.fields[1]).unit, .percentRelativeHumidity)
        XCTAssertEqual(try number(r.fields[0]).unit, .unknown)
        XCTAssertEqual(try decode([1, 4, 0, 0, 0], category: 29).issue, .unsupportedKey(MeasurementKey(4, 0), category: 29))
        XCTAssertEqual(try decode([1, 0x0B, 0, 0, 0], category: 4).issue, .unsupportedKey(MeasurementKey(0x0B, 0), category: 4))
    }
    func testAuxiliaryPressureSentinelIsNewManifoldOnly() throws {
        for category in [29, 34, 35] {
            let r = try decode([2, 0x18, 0, 0xFF, 0xF0, 0xBD, 0xC0, 0x19, 0, 1, 0, 0, 0], category: category)
            XCTAssertEqual(r.fields[0].value, .missing(rawInteger: -1061293825))
            XCTAssertEqual(r.fields.map(\.semantic), [.auxiliaryHighPressure, .auxiliaryLowPressure])
            XCTAssertEqual(try number(r.fields[1]).value, 1)
        }
        XCTAssertEqual(try decode([1, 0x18, 0, 1, 0, 0, 0], category: 8).issue, .unsupportedKey(MeasurementKey(0x18, 0), category: 8))
    }
    func testWrongCommandsIncludingConfigurationCollisionsRejected() {
        for command: UInt8 in [1, 2, 4, 5, 6, 0x82, 0x83, 0x84, 0x85] {
            XCTAssertThrowsError(try Measurements.decode(frame([1, 1, 0, 10], command: command), context: MeasurementContext(category: 29))) {
                XCTAssertEqual($0 as? MeasurementError, .unexpectedCommand(command))
            }
        }
    }
    func testInvalidChecksumEvenInspectionPacketRejected() throws {
        var bytes = frame([1, 1, 0, 10]).bytes
        bytes[bytes.count - 1] ^= 1
        let p = try Packet.decode(bytes, checksumPolicy: .report)
        XCTAssertThrowsError(try Measurements.decode(p, context: MeasurementContext(category: 29))) {
            XCTAssertEqual($0 as? PacketError, .checksumMismatch(expected: p.expectedChecksum, actual: p.checksum))
        }
    }
    func testPartialFramesRequirePacketValidationBeforeMeasurements() {
        for bytes: [UInt8] in [[], [1], [1, 0], [1, 0, 3]] {
            XCTAssertThrowsError(try Packet.decode(bytes))
        }
        XCTAssertThrowsError(try Packet.decode([1, 0, 3, 1, 5, 0, 0]))
    }
    func testAllSupportedScalarPathsAndOpaqueCategory10Field() throws {
        for (key, semantic): (UInt8, MeasurementSemantic) in [(3, .highTemperature), (6, .highPressure), (0x18, .auxiliaryHighPressure), (0x19, .auxiliaryLowPressure)] {
            let bytes: [UInt8] = key == 3 ? [0xFF, 0x7F] : [0xFF, 0xFF, 0xFF, 0x7F]
            let r = try decode([1, key, 0] + bytes)
            XCTAssertTrue(r.isComplete)
            XCTAssertEqual(r.fields[0].semantic, semantic)
            XCTAssertEqual(try number(r.fields[0]).rawInteger, key == 3 ? 32767 : 2147483647)
        }
        XCTAssertEqual(try number(decode([1, 4, 0, 0, 0x80], category: 9).fields[0]).rawInteger, -32768)
        let unknownMeaning = try decode([1, 0x0C, 0, 0xFF, 0xFF], category: 10)
        XCTAssertTrue(unknownMeaning.isComplete)
        XCTAssertEqual(unknownMeaning.fields[0].value, .opaque)
        XCTAssertEqual(try number(decode([1, 0x0B, 0, 0xFF, 0xFF], category: 10).fields[0]).rawInteger, 65535)
        XCTAssertEqual(try decode([1, 0, 5, 0, 0, 0, 0]).issue, .unknownKey(MeasurementKey(0, 5)))
    }
    func testEveryPayloadPrefixAndSyntheticByteSequenceHasLosslessAccounting() throws {
        let complete: [UInt8] = [4, 1, 0, 87, 2, 0, 0x12, 0xFF, 5, 0, 0x78, 0x56, 0x34, 0x12, 0x14, 0, 0xAA, 0xBB]
        var payloads = (0...complete.count).map { Array(complete.prefix($0)) }
        // Deterministic generated bytes, not a packet-length or hardware model hypothesis.
        for count in 0...255 {
            payloads.append([UInt8(count)] + (0..<count).map { UInt8(truncatingIfNeeded: $0 * 73 + count) })
        }
        for payload in payloads {
            let r = try decode(payload)
            let consumed = r.fields.flatMap { $0.key.bytes + $0.rawValue }
            let reconstructed = (payload.isEmpty ? [] : [payload[0]]) + consumed + r.unparsedRemainder
            XCTAssertEqual(reconstructed, payload)
            XCTAssertLessThanOrEqual(r.fields.count, Int(payload.first ?? 0))
            if r.isComplete {
                XCTAssertEqual(r.fields.count, Int(payload.first ?? 0))
                XCTAssertTrue(r.unparsedRemainder.isEmpty)
            }
        }
    }
    func testHexCaseDoesNotChangeWireKeys() throws {
        let p = frame([1, 0x0B, 0, 0x2B, 2])
        let parsed = try Packet.decode(hex: p.hex.lowercased())
        XCTAssertEqual(try Measurements.decode(parsed, context: MeasurementContext(category: 10)).fields[0].key, MeasurementKey(0x0B, 0))
    }
}
