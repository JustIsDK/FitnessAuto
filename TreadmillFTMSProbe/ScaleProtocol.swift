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
