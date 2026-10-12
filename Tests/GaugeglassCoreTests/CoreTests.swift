import XCTest
@testable import GaugeglassCore

// All vectors are GENERATED fixtures using source-derived rules, not hardware captures.
final class HexTests: XCTestCase {
    func testMixedCaseAndASCIIWhitespace() throws {
        XCTAssertEqual(try Hex.decode("aB 00\tCd\r\nEF"), [0xAB, 0, 0xCD, 0xEF])
    }
    func testEmptyAndWhitespace() throws {
        XCTAssertEqual(try Hex.decode(""), [])
        XCTAssertEqual(try Hex.decode(" \t\r\n"), [])
    }
    func testUppercaseEncodingAndAllByteRoundTrip() throws {
        let bytes = Array(UInt8.min...UInt8.max)
        XCTAssertEqual(Hex.encode([0, 0x0A, 0xFF]), "000AFF")
        XCTAssertEqual(try Hex.decode(Hex.encode(bytes)), bytes)
    }
    func testOddNibbleCount() {
        XCTAssertThrowsError(try Hex.decode("A BC D E")) {
            XCTAssertEqual($0 as? HexError, .oddDigitCount(5))
        }
    }
    func testRejectsPrefixesPunctuationAndNonASCII() {
        for text in ["0x01", "AA:BB", "AA-BB", "GG", "é", "ＡＡ", "AA\u{00A0}BB"] {
            XCTAssertThrowsError(try Hex.decode(text), text)
        }
    }
    func testInvalidByteOffset() {
        XCTAssertThrowsError(try Hex.decode("AA ?")) {
            XCTAssertEqual($0 as? HexError, .invalidCharacter(byteOffset: 3))
        }
    }
}

final class ChecksumTests: XCTestCase {
    func testEmptyAndZero() {
        XCTAssertEqual(BCC.calculate([]), 0)
        XCTAssertEqual(BCC.calculate([0, 0]), 0)
    }
    func testWrappingNegationNotComplementOrPlainXOR() {
        XCTAssertEqual(BCC.calculate([1]), 0xFF)
        XCTAssertEqual(BCC.calculate([0xFF]), 1)
        XCTAssertEqual(BCC.calculate([0x80]), 0x80)
    }
    func testGeneratedAuthenticationReplyVector() {
        XCTAssertEqual(BCC.calculate([1, 3, 1, 2, 0x0A]), 0xF5)
    }
    func testEverySingleByteAndCancellation() {
        for byte in UInt8.min...UInt8.max {
            XCTAssertEqual(BCC.calculate([byte]), 0 &- byte)
            XCTAssertEqual(BCC.calculate([byte, byte]), 0)
        }
    }
}

final class PacketTests: XCTestCase {
    func testGeneratedFrameFieldsAndRoundTrip() throws {
        let packet = try Packet.decode(hex: "01 03 01 02 0A F5")
        XCTAssertEqual(packet.handle, 1)
        XCTAssertEqual(packet.rawLength, 3)
        XCTAssertEqual(packet.command, 1)
        XCTAssertEqual(packet.payload, [2, 0x0A])
        XCTAssertEqual(packet.checksum, 0xF5)
        XCTAssertEqual(packet.expectedChecksum, 0xF5)
        XCTAssertTrue(packet.isChecksumValid)
        XCTAssertEqual(packet.hex, "010301020AF5")
        XCTAssertEqual(try Packet.decode(packet.bytes), packet)
    }
    func testMinimumFrameAndUnknownLengthRemainRaw() throws {
        let packet = try Packet.decode(hex: "A500EEB5")
        XCTAssertEqual(packet.payload, [])
        XCTAssertEqual(packet.rawLength, 0)
        XCTAssertEqual(packet.command, 0xEE)
    }
    func testEveryTooShortLength() {
        for count in 0..<4 {
            XCTAssertThrowsError(try Packet.decode(Array(repeating: 0, count: count))) {
                XCTAssertEqual($0 as? PacketError, .tooShort(actual: count))
            }
        }
    }
    func testMismatchRejectedByDefault() {
        XCTAssertThrowsError(try Packet.decode(hex: "010301020AF4")) {
            XCTAssertEqual($0 as? PacketError, .checksumMismatch(expected: 0xF5, actual: 0xF4))
        }
    }
    func testInspectionRetainsInvalidChecksum() throws {
        let packet = try Packet.decode(hex: "010301020AF4", checksumPolicy: .report)
        XCTAssertFalse(packet.isChecksumValid)
        XCTAssertEqual(packet.checksum, 0xF4)
        XCTAssertEqual(packet.hex, "010301020AF4")
    }
    func testExplicitLengthAndLargePayloadNoInventedLengthValidation() throws {
        let payload = Array(UInt8.min...UInt8.max)
        let packet = Packet(handle: 0xFF, rawLength: 1, command: 0xFE, payload: payload)
        XCTAssertEqual(packet.rawLength, 1)
        XCTAssertEqual(try Packet.decode(packet.bytes), packet)
    }
    func testHexErrorsPropagate() {
        XCTAssertThrowsError(try Packet.decode(hex: "010")) {
            XCTAssertEqual($0 as? HexError, .oddDigitCount(3))
        }
    }
}

final class AuthenticationTests: XCTestCase {
    private func frame(_ payload: [UInt8], command: UInt8 = 1) -> Packet {
        Packet(handle: 1, rawLength: 0, command: command, payload: payload)
    }
    func testGeneratedChallengeDecodeAndReply() throws {
        let incoming = try Packet.decode(hex: "0106010112345678F1")
        let challenge = try AuthenticationChallenge(bytes: [0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(try Authentication.decode(incoming), .challenge(challenge))
        XCTAssertEqual(challenge.response, 0x90)
        XCTAssertEqual(challenge.reply.hex, "01030102906F")
        XCTAssertEqual(challenge.reply.handle, 1)
        XCTAssertEqual(challenge.reply.rawLength, 3)
    }
    func testResponseOverflowAndZero() throws {
        XCTAssertEqual(try AuthenticationChallenge(bytes: [0xFF, 0xFF, 0, 0]).response, 0xFE)
        XCTAssertEqual(try AuthenticationChallenge(bytes: [0, 0, 0, 0]).response, 0)
        XCTAssertEqual(try AuthenticationChallenge(bytes: [1, 2, 3, 4]).reply.hex, "0103010208F7")
    }
    func testChallengeRequiresExactlyFourBytes() {
        for count in [0, 1, 2, 3, 5, 256] {
            XCTAssertThrowsError(try AuthenticationChallenge(bytes: Array(repeating: 0, count: count))) {
                XCTAssertEqual($0 as? AuthenticationError, .invalidChallengeLength(actual: count))
            }
        }
    }
    func testSourceDerivedSuccessStatus() throws {
        XCTAssertEqual(try Authentication.decode(Packet.decode(hex: "010301030000")), .status(.accepted))
    }
    func testNonzeroStatusPreservedNotExplained() throws {
        XCTAssertEqual(try Authentication.decode(Packet.decode(hex: "010301037F81")), .status(.rejected(code: 0x7F)))
        XCTAssertEqual(try Authentication.decode(frame([3, 0xFF])), .status(.rejected(code: 0xFF)))
    }
    func testOtherCommandsAndUnsupportedSubcommandsRejected() {
        XCTAssertThrowsError(try Authentication.decode(frame([1, 0, 0, 0, 0], command: 5))) {
            XCTAssertEqual($0 as? AuthenticationError, .unexpectedCommand(5))
        }
        for subcommand: UInt8 in [0, 2, 4, 0xFF] {
            XCTAssertThrowsError(try Authentication.decode(frame([subcommand]))) {
                XCTAssertEqual($0 as? AuthenticationError, .unsupportedSubcommand(subcommand))
            }
        }
    }
    func testEmptyAndMalformedKnownPayloadsRejected() {
        XCTAssertThrowsError(try Authentication.decode(frame([]))) {
            XCTAssertEqual($0 as? AuthenticationError, .missingSubcommand)
        }
        for payload: [UInt8] in [[1], [1, 0, 0, 0], [1, 0, 0, 0, 0, 0], [3], [3, 0, 0]] {
            XCTAssertThrowsError(try Authentication.decode(frame(payload))) {
                XCTAssertEqual($0 as? AuthenticationError,
                    .invalidPayloadLength(subcommand: payload[0], expected: payload[0] == 1 ? 5 : 2, actual: payload.count))
            }
        }
    }
    func testInvalidChecksumNeverBecomesAuthenticationEvent() throws {
        let packet = try Packet.decode(hex: "010301030001", checksumPolicy: .report)
        XCTAssertThrowsError(try Authentication.decode(packet)) {
            XCTAssertEqual($0 as? PacketError, .checksumMismatch(expected: 0, actual: 1))
        }
    }
    func testReplyHandleIsFixedNotEchoed() throws {
        let incoming = Packet(handle: 0xA5, rawLength: 0xFF, command: 1, payload: [1, 1, 2, 3, 4])
        guard case .challenge(let challenge) = try Authentication.decode(incoming) else {
            return XCTFail("Expected challenge")
        }
        XCTAssertEqual(challenge.reply.hex, "0103010208F7")
    }
}
