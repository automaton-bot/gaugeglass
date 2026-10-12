import Foundation
import GaugeglassCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// Offline-only diagnostic: never connects or transmits the computed reply.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
    print("Usage: gaugeglass-inspect [--report-checksum] HEX_FRAME")
    print("Decodes one complete frame offline. No equipment commands are sent.")
    exit(0)
}
var input = arguments
let report = input.first == "--report-checksum"
if report { input.removeFirst() }
guard !input.isEmpty else {
    FileHandle.standardError.write(Data("Usage: gaugeglass-inspect [--report-checksum] HEX_FRAME\n".utf8))
    exit(2)
}
do {
    let packet = try Packet.decode(hex: input.joined(separator: " "), checksumPolicy: report ? .report : .requireValid)
    print("frame=\(packet.hex)")
    print("handle=\(Hex.encode([packet.handle])) rawLength=\(Hex.encode([packet.rawLength])) command=\(Hex.encode([packet.command]))")
    print("payload=\(Hex.encode(packet.payload))")
    print("checksum=\(Hex.encode([packet.checksum])) expected=\(Hex.encode([packet.expectedChecksum])) valid=\(packet.isChecksumValid)")
    if packet.command == 1 && packet.isChecksumValid {
        do {
            switch try Authentication.decode(packet) {
            case .challenge(let challenge):
                print("authentication=challenge response=\(Hex.encode([challenge.response]))")
                print("computedReply=\(challenge.reply.hex) (not transmitted)")
            case .status(.accepted): print("authentication=accepted")
            case .status(.rejected(let code)): print("authentication=rejected status=\(Hex.encode([code]))")
            }
        } catch {
            print("authentication=unrecognized error=\(error)")
        }
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
