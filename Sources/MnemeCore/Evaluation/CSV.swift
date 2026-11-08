import Foundation

/// RFC 4180 CSV parsing: quoted fields, escaped quotes, embedded commas and line breaks, CRLF or LF.
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var fieldStarted = false
        let scalars = Array(text.unicodeScalars)
        var index = scalars.first == "\u{FEFF}" ? 1 : 0

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            fieldStarted = false
        }

        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) {
                rows.append(row)
            }
            row = []
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count && scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(scalar)
                }
            } else {
                switch scalar {
                case "\"":
                    inQuotes = true
                    fieldStarted = true
                case ",":
                    endField()
                case "\r":
                    endRow()
                    if index + 1 < scalars.count && scalars[index + 1] == "\n" {
                        index += 1
                    }
                case "\n":
                    endRow()
                default:
                    field.append(scalar)
                    fieldStarted = true
                }
            }
            index += 1
        }
        if fieldStarted || !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }

    /// Rows as dictionaries keyed by the header row.
    public static func records(_ text: String) -> [[String: String]] {
        let rows = parse(text)
        guard let header = rows.first else { return [] }
        let keys = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return rows.dropFirst().map { (row: [String]) -> [String: String] in
            var record: [String: String] = [:]
            for (index, key) in keys.enumerated() where !key.isEmpty && index < row.count {
                record[key] = row[index]
            }
            return record
        }
    }
}
