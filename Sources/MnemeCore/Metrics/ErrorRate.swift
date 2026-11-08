import Foundation

/// Substitutions, deletions and insertions of a minimum-edit alignment against a reference.
public struct EditCounts: Codable, Equatable, Sendable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceLength: Int

    public static let zero = EditCounts()

    public init(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0, referenceLength: Int = 0) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceLength = referenceLength
    }

    public var errors: Int {
        substitutions + deletions + insertions
    }

    /// Errors divided by reference length; nil when the reference is empty.
    public var rate: Double? {
        referenceLength > 0 ? Double(errors) / Double(referenceLength) : nil
    }

    public static func + (lhs: EditCounts, rhs: EditCounts) -> EditCounts {
        EditCounts(
            substitutions: lhs.substitutions + rhs.substitutions,
            deletions: lhs.deletions + rhs.deletions,
            insertions: lhs.insertions + rhs.insertions,
            referenceLength: lhs.referenceLength + rhs.referenceLength
        )
    }
}

private struct AlignmentCell {
    var cost: Int
    var substitutions: Int
    var deletions: Int
    var insertions: Int
}

public enum ErrorRate {
    /// Levenshtein alignment with a deterministic breakdown (substitution, then deletion, then insertion on ties).
    public static func align<T: Equatable>(reference: [T], hypothesis: [T]) -> EditCounts {
        let referenceCount = reference.count
        let hypothesisCount = hypothesis.count
        if referenceCount == 0 {
            return EditCounts(insertions: hypothesisCount, referenceLength: 0)
        }
        if hypothesisCount == 0 {
            return EditCounts(deletions: referenceCount, referenceLength: referenceCount)
        }
        var previous = (0...hypothesisCount).map {
            AlignmentCell(cost: $0, substitutions: 0, deletions: 0, insertions: $0)
        }
        var current = previous
        for row in 1...referenceCount {
            current[0] = AlignmentCell(cost: row, substitutions: 0, deletions: row, insertions: 0)
            for column in 1...hypothesisCount {
                if reference[row - 1] == hypothesis[column - 1] {
                    current[column] = previous[column - 1]
                    continue
                }
                let substitution = previous[column - 1]
                let deletion = previous[column]
                let insertion = current[column - 1]
                var cell: AlignmentCell
                if substitution.cost <= deletion.cost && substitution.cost <= insertion.cost {
                    cell = substitution
                    cell.substitutions += 1
                } else if deletion.cost <= insertion.cost {
                    cell = deletion
                    cell.deletions += 1
                } else {
                    cell = insertion
                    cell.insertions += 1
                }
                cell.cost += 1
                current[column] = cell
            }
            swap(&previous, &current)
        }
        let result = previous[hypothesisCount]
        return EditCounts(
            substitutions: result.substitutions,
            deletions: result.deletions,
            insertions: result.insertions,
            referenceLength: referenceCount
        )
    }

    /// Word errors after normalisation. Not meaningful for languages written without spaces; use characters.
    public static func wordErrors(reference: String, hypothesis: String) -> EditCounts {
        align(reference: words(reference), hypothesis: words(hypothesis))
    }

    /// Character errors after normalisation, ignoring spaces.
    public static func characterErrors(reference: String, hypothesis: String) -> EditCounts {
        align(reference: characters(reference), hypothesis: characters(hypothesis))
    }

    static func words(_ text: String) -> [String] {
        TextNormalizer.normalize(text).split(separator: " ").map(String.init)
    }

    static func characters(_ text: String) -> [Character] {
        Array(TextNormalizer.normalize(text).filter { $0 != " " })
    }
}
