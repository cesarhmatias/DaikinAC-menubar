import Foundation

// Local LAN channel (phase 6). Only the frame checksum exists so far.
enum LocalChannel {
    static let port: UInt16 = 15914
    static let serviceType = "_iota._tcp"
}

// CRC-16/GENIBUS: polynomial 0x1021, MSB first, init 0xFFFF, final xor 0xFFFF.
// The table is generated from the polynomial rather than copied.
enum CRC16 {
    static let table: [UInt16] = (0..<256).map { index in
        var value = UInt16(index) << 8
        for _ in 0..<8 { value = value & 0x8000 != 0 ? (value << 1) ^ 0x1021 : value << 1 }
        return value
    }

    static func genibus<Bytes: Sequence>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes { crc = (crc << 8) ^ table[Int(UInt8(crc >> 8) ^ byte)] }
        return ~crc
    }
}
