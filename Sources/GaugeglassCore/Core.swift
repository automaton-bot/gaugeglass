/// Independent source-derived packet primitives. No transport or equipment control.
public enum HexError: Error, Equatable, Sendable {
    case oddDigitCount(Int)
    case invalidCharacter(byteOffset: Int)
}

public enum Hex {
    /// Accept ASCII hex digits and ASCII whitespace only; offsets refer to UTF-8 bytes.
    public static func decode(_ text: String) throws -> [UInt8] {
        var digits: [UInt8] = []
        digits.reserveCapacity(text.utf8.count)
        for (offset, byte) in text.utf8.enumerated() {
            switch byte {
            case 9...13, 32: continue
            case 48...57: digits.append(byte - 48)
            case 65...70: digits.append(byte - 55)
            case 97...102: digits.append(byte - 87)
            default: throw HexError.invalidCharacter(byteOffset: offset)
            }
        }
        guard digits.count.isMultiple(of: 2) else {
            throw HexError.oddDigitCount(digits.count)
        }
        var result: [UInt8] = []
        result.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            result.append((digits[index] << 4) | digits[index + 1])
        }
        return result
    }

    public static func encode(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789ABCDEF".utf8)
        return String(decoding: bytes.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }, as: UTF8.self)
    }
}

public enum BCC {
    /// Wrapping negation of bytewise XOR, not a CRC or one's complement.
    public static func calculate(_ bytes: [UInt8]) -> UInt8 {
        0 &- bytes.reduce(0, ^)
    }
}

public enum ChecksumPolicy: Sendable { case requireValid, report }
public enum PacketError: Error, Equatable, Sendable {
    case tooShort(actual: Int)
    case checksumMismatch(expected: UInt8, actual: UInt8)
}

/// Exactly one externally delimited frame. rawLength semantics remain unresolved.
/// This type is not a stream deframer and performs no BLE writes.
public struct Packet: Equatable, Sendable {
    public let handle: UInt8
    public let rawLength: UInt8
    public let command: UInt8
    public let payload: [UInt8]
    public let checksum: UInt8
    private var content: [UInt8] { [handle, rawLength, command] + payload }
    public var bytes: [UInt8] { content + [checksum] }
    public var hex: String { Hex.encode(bytes) }
    public var expectedChecksum: UInt8 { BCC.calculate(content) }
    public var isChecksumValid: Bool { checksum == expectedChecksum }

    /// The caller supplies rawLength explicitly; no inferred wire-length contract.
    public init(handle: UInt8, rawLength: UInt8, command: UInt8, payload: [UInt8]) {
        self.handle = handle
        self.rawLength = rawLength
        self.command = command
        self.payload = payload
        self.checksum = BCC.calculate([handle, rawLength, command] + payload)
    }

    private init(handle: UInt8, rawLength: UInt8, command: UInt8, payload: [UInt8], checksum: UInt8) {
        self.handle = handle
        self.rawLength = rawLength
        self.command = command
        self.payload = payload
        self.checksum = checksum
    }

    public static func decode(_ bytes: [UInt8], checksumPolicy: ChecksumPolicy = .requireValid) throws -> Packet {
        guard bytes.count >= 4 else { throw PacketError.tooShort(actual: bytes.count) }
        let packet = Packet(handle: bytes[0], rawLength: bytes[1], command: bytes[2],
                            payload: Array(bytes[3..<(bytes.count - 1)]), checksum: bytes[bytes.count - 1])
        if case .requireValid = checksumPolicy, !packet.isChecksumValid {
            throw PacketError.checksumMismatch(expected: packet.expectedChecksum, actual: packet.checksum)
        }
        return packet
    }

    public static func decode(hex: String, checksumPolicy: ChecksumPolicy = .requireValid) throws -> Packet {
        try decode(Hex.decode(hex), checksumPolicy: checksumPolicy)
    }
}

public enum AuthenticationError: Error, Equatable, Sendable {
    case invalidChallengeLength(actual: Int)
    case unexpectedCommand(UInt8)
    case missingSubcommand
    case unsupportedSubcommand(UInt8)
    case invalidPayloadLength(subcommand: UInt8, expected: Int, actual: Int)
}

public struct AuthenticationChallenge: Equatable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws {
        guard bytes.count == 4 else { throw AuthenticationError.invalidChallengeLength(actual: bytes.count) }
        self.bytes = bytes
    }
    public var response: UInt8 { (bytes[0] ^ bytes[2]) &+ (bytes[1] ^ bytes[3]) }
    /// Builds the observed response bytes only. Does not send or initiate authentication.
    public var reply: Packet { Packet(handle: 1, rawLength: 3, command: 1, payload: [2, response]) }
}

public enum AuthenticationStatus: Equatable, Sendable { case accepted, rejected(code: UInt8) }
public enum AuthenticationEvent: Equatable, Sendable {
    case challenge(AuthenticationChallenge)
    case status(AuthenticationStatus)
}

public enum Authentication {
    /// Strict interpretation of the two source-supported payload shapes.
    /// Extra bytes are rejected pending protocol evidence, not silently ignored.
    public static func decode(_ packet: Packet) throws -> AuthenticationEvent {
        guard packet.isChecksumValid else {
            throw PacketError.checksumMismatch(expected: packet.expectedChecksum, actual: packet.checksum)
        }
        guard packet.command == 1 else { throw AuthenticationError.unexpectedCommand(packet.command) }
        guard let subcommand = packet.payload.first else { throw AuthenticationError.missingSubcommand }
        let expected: Int
        switch subcommand {
        case 1: expected = 5
        case 3: expected = 2
        default: throw AuthenticationError.unsupportedSubcommand(subcommand)
        }
        guard packet.payload.count == expected else {
            throw AuthenticationError.invalidPayloadLength(subcommand: subcommand, expected: expected, actual: packet.payload.count)
        }
        if subcommand == 1 {
            return .challenge(try AuthenticationChallenge(bytes: Array(packet.payload.dropFirst())))
        }
        let code = packet.payload[1]
        return .status(code == 0 ? .accepted : .rejected(code: code))
    }
}
