import Foundation

/// AFU-WL-TZ-A1 only. Byte positions and checksums verified against its capture.
struct ScaleReading: Equatable {
    let kilograms: Double
    let stable: Bool
    let resistance1: Int?
    let resistance2: Int?

    static func decode(_ data: Data) -> ScaleReading? {
        let b = Array(data)
        guard b.count == 20, b[0] == 0xAC, b[1] == 0x29,
              b[2...18].reduce(0, { $0 + Int($1) }) & 0x1F == Int(b[19]) else { return nil }
        let offset: Int
        switch b[18] {
        case 0xD5: offset = 2
        case 0xD6:
            guard b[2] == 2 else { return nil }
            offset = 9
        default: return nil
        }
        let packed = b[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let weight = Double(packed & 0x3FFFF) / 1000
        guard weight >= 1, weight <= 250 else { return nil }
        let final = b[18] == 0xD6
        return ScaleReading(kilograms: weight, stable: packed & 0x80000000 != 0,
                            resistance1: final ? Int(b[5]) | Int(b[6]) << 8 : nil,
                            resistance2: final ? Int(b[7]) | Int(b[8]) << 8 : nil)
    }

    static func bmi(weight: Double, heightCm: Double) -> Double? {
        guard weight.isFinite, weight > 0, heightCm.isFinite, (90...240).contains(heightCm) else { return nil }
        return weight / pow(heightCm / 100, 2)
    }

    // Only the final measurement acknowledgement is sent; no profile/history/DFU commands.
    static let finalAcknowledgement = Data([0xAC, 0x27, 0x04, 0xD6, 0, 0, 0, 0, 0, 0,
                                          0, 0, 0, 0, 0, 0, 0, 0, 0xDF, 0xB9])
}

struct WeightRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let kilograms: Double
    let heightCm: Double?
    let resistance1: Int?
    let resistance2: Int?
    var bmi: Double? { heightCm.flatMap { ScaleReading.bmi(weight: kilograms, heightCm: $0) } }
}

/// Field interpretation is provisional until verified on the A1 hardware.
struct ScaleProfile {
    let heightCm: Int
    let age: Int
    let male: Bool
    let referenceKg: Double
    var valid: Bool {
        (90...240).contains(heightCm) && (10...100).contains(age)
            && referenceKg.isFinite && (1...250).contains(referenceKg)
    }
    func initialization(at date: Date = Date()) -> [Data] {
        guard valid, date.timeIntervalSince1970 >= 0,
              date.timeIntervalSince1970 <= Double(UInt32.max) else { return [] }
        let seconds = UInt32(date.timeIntervalSince1970)
        let timestamp = (0..<4).map { UInt8((seconds >> (24 - $0 * 8)) & 255) }
        let reference = Int((referenceKg * 100).rounded())
        let user: [UInt8] = [0, 1, UInt8(heightCm), UInt8(reference >> 8), UInt8(reference & 255),
                             UInt8(age), male ? 1 : 0]
        // 13 88 03 00 is an opaque captured trailer, not a confirmed target weight.
        return [Self.frame(type: 0xDF, payload: [8] + timestamp + [0x20]),
                Self.frame(type: 0xD1, payload: [1] + user),
                Self.frame(type: 0xD0, payload: timestamp + [0x20] + user +
                           [0x13, 0x88, 3, 0]),
                Self.frame(type: 0xDF, payload: [6])]
    }
    static func frame(type: UInt8, payload: [UInt8]) -> Data {
        precondition(payload.count <= 16)
        var bytes: [UInt8] = [0xAC, 0x27] + payload + Array(repeating: 0, count: 16 - payload.count) + [type]
        bytes.append(UInt8(bytes[2...18].reduce(0, { $0 + Int($1) }) & 255))
        return Data(bytes)
    }
    static let closeReport = frame(type: 0xDF, payload: [7])
    static func reportChunkIndex(_ data: Data) -> Int? {
        let b = Array(data)
        guard b.count == 20, b[0] == 0xAC, b[1] == 0x29, b[2] == 6, b[18] == 0xDF,
              b[2...18].reduce(0, { $0 + Int($1) }) & 31 == Int(b[19]), b[3] <= 4 else { return nil }
        return Int(b[3])
    }
}
