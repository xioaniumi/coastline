import Foundation
@testable import CRCore

private func fixture(_ name: String) throws -> IntelHex {
    let url = repoRoot.appending(path: "reference/fixtures/\(name)")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Skip(reason: "\(name) missing") }
    return try IntelHex(text: text)
}

let firmwareTests: [TestCase] = [
    TestCase(name: "intelHexParsing") {
        let hex = try IntelHex(text: ":10010000214601360121470136007EFE09D2190140\n:00000001FF\n")
        try expectEqual(hex.bytes.count, 16)
        try expectEqual(hex.bytes[0x100], 0x21)
        try expectEqual(hex.bytes[0x10F], 0x01)
        try expectThrows { _ = try IntelHex(text: ":10010000214601360121470136007EFE09D2190141\n") }
        let pages = hex.pages(size: 128)
        try expectEqual(pages.count, 1)
        try expectEqual(pages[0].address, 0x100 / 128 * 128)
    },

    TestCase(name: "realFirmwareFilesParse") {
        let cr = try fixture("cr_328p_20240318.hex")
        let vfd = try fixture("32M1_20240502.hex")
        try expect(cr.highestAddress < AVRDevice.atmega328p.flashSize)
        try expect(vfd.highestAddress < AVRDevice.atmega32m1.flashSize)
        print("    328P firmware: \(cr.bytes.count) bytes, 32M1 firmware: \(vfd.bytes.count) bytes")
    },

    TestCase(name: "programAndVerifyOnMockBootloader") {
        let image = try fixture("cr_328p_20240318.hex")
        let mock = MockSTK500()
        let programmer = STK500Programmer(port: mock)
        var last = 0.0
        try programmer.program(image, device: .atmega328p) { last = $0 }
        try expect(mock.erased)
        try expectEqual(last, 1)
        for (address, byte) in image.bytes { try expectEqual(mock.flash[address], byte, "address \(address)") }
    },

    TestCase(name: "wrongChipIsRefused") {
        let image = try IntelHex(text: ":10000000214601360121470136007EFE09D2190141\n:00000001FF\n")
        let mock = MockSTK500(signature: AVRDevice.atmega32m1.signature)
        do {
            try STK500Programmer(port: mock).program(image, device: .atmega328p)
            throw TestFailure(description: "expected signature mismatch")
        } catch let error as STK500Error {
            try expect(error.description.contains("Wrong chip"), error.description)
        }
        try expect(!mock.erased, "must not erase the wrong chip")
    },

    TestCase(name: "bootloaderSectionIsProtected") {
        // Data at 0x7E00 (Optiboot's section) must be refused for the 328P.
        var bytes = [Int: UInt8]()
        bytes[0x7E00] = 0x0C
        try expectThrows { try STK500Programmer(port: MockSTK500()).program(IntelHex(bytes: bytes), device: .atmega328p) }
    },

    TestCase(name: "malformedExtendedAddressRecord") {
        try expectThrows { _ = try IntelHex(text: ":00000002FE\n") }
    },

    TestCase(name: "firmwareVersionParsing") {
        let v = FirmwareVersion.parse("[grbl:1.1g CR:3A PCB:3B VFD:00 YMD:20240318]")
        try expectEqual(v, FirmwareVersion(grbl: "1.1g", ymd: "20240318", cr: "3A", pcb: "3B", vfd: "00"))
    },
]
