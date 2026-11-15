import Foundation

struct WeightReading: Equatable {
    let weightKg: Double
    let bmi: Double?
    let fatPercent: Double?
    let tbwPercent: Double?
    let bmcKg: Double?
    let smPercent: Double?
    let mt: Double?
    let userID: String?
    let resultID: String
    let date: Date

    var leanBodyMassKg: Double? {
        fatPercent.map { weightKg * (1 - $0 / 100) }
    }
}

enum QardioBaseParseError: Error, Equatable {
    case emptyPayload
    case invalidJSON
    case missingWeight
    case missingID
}

enum QardioBaseResultParser {
    static func parse(_ data: Data) throws -> WeightReading {
        var bytes = [UInt8](data)
        while let last = bytes.last, last == 0 || isWhitespace(last) {
            bytes.removeLast()
        }
        guard !bytes.isEmpty else { throw QardioBaseParseError.emptyPayload }

        guard
            let object = try? JSONSerialization.jsonObject(with: Data(bytes)),
            let fields = object as? [String: Any]
        else {
            throw QardioBaseParseError.invalidJSON
        }

        guard let weightKg = number(fields["weight"]) else {
            throw QardioBaseParseError.missingWeight
        }
        guard
            let resultID = text(fields["id"]),
            resultID.count >= 10,
            let timestamp = TimeInterval(resultID.suffix(10))
        else {
            throw QardioBaseParseError.missingID
        }

        return WeightReading(
            weightKg: weightKg,
            bmi: number(fields["bmi"]),
            fatPercent: number(fields["fat"]),
            tbwPercent: number(fields["tbw"]),
            bmcKg: number(fields["bmc"]),
            smPercent: number(fields["sm"]),
            mt: number(fields["mt"]),
            userID: text(fields["userid"]),
            resultID: resultID,
            date: Date(timeIntervalSince1970: timestamp)
        )
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
