import Foundation

/// A paper's title as its DOI registered it, and the one question the library
/// asks of it: is the title the paper carries that title with characters lost?
///
/// PDF text extraction drops a glyph its font draws but cannot map back to a
/// character — a Greek letter set in a symbol font, a superscript, a minus —
/// and the metadata model, reading that text, faithfully returns the title
/// without it. J Neurosci's PDF of Tretter & Adam-Vizi (2004) gave the
/// library "…Catalyzed by -Ketoglutarate Dehydrogenase", where Crossref and
/// the printed page have "α-Ketoglutarate". The model cannot restore what its
/// input does not hold, so the catalog's copy is the only place the letter
/// survives.
///
/// Deliberately a deterministic comparison, not a model call: the question is
/// whether one string is another with characters missing, and the answer has
/// to be safe against a paper whose stored DOI names a different work (about
/// a dozen in the production library do). The rule accepts the registered
/// title only when the held title is it with nothing but non-ASCII
/// characters lost, or stood in for by U+FFFD — PDF text maps ASCII
/// reliably, so an ASCII difference is an edition's, not the extraction's:
/// "aging" against "ageing", a footnote letter in the catalog's
/// "…Birdsa", a web headline against the print one. Whitespace, format
/// characters (a soft hyphen) and typographic variants (compatibility forms,
/// dashes, quotes) are not differences, with one exception: a space between
/// two letters is a character PDF text can lose too. A title set by glyph
/// position rather than with space characters reads back with its words run
/// together — JACS's PDF gave "EngineeredMetal-OrganicFrameworksPreserve
/// Mitochondrial BioenergeticsatMicromolarConcentrations" — so a copy that
/// joins two words the registered title keeps apart lost characters. A space
/// beside a digit or a sign stays typography ("Ca2+" against "Ca ²⁺"). A
/// title that differs in case, or lost more than it kept, is left alone.
/// Ligature loss ("Specific" read as "Specic") drops ASCII letters and is out
/// of reach by the same rule.
enum RegisteredPaperTitle {
    /// The registered title, whitespace collapsed, when `title` is a copy of
    /// it that lost characters; nil when `title` should stand.
    static func restoringLostCharacters(in title: String, registered: String?) -> String? {
        guard let registered else { return nil }
        let clean = registered
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !clean.isEmpty, clean != title, isCopyWithLostCharacters(title, of: clean) else {
            return nil
        }
        return clean
    }

    /// Whether `damaged` is `registered` with only non-ASCII characters lost
    /// or replaced by a placeholder, or with words run together, and at
    /// least one lost.
    static func isCopyWithLostCharacters(_ damaged: String, of registered: String) -> Bool {
        let held = units(of: damaged)
        let reference = units(of: registered)
        let placeholders = held.reduce(0) { $0 + ($1.isPlaceholder ? 1 : 0) }
        guard !held.isEmpty, reference.count >= held.count else { return false }
        let lost = reference.count - held.count + placeholders
        let kept = held.count - placeholders
        guard lost <= kept else { return false }
        // Every character kept: the copy lost something only if it ran two
        // of the registered title's words together.
        if lost == 0 {
            return zip(held, reference).allSatisfy { $0.character == $1.character }
                && runsWordsTogether(held, of: reference)
        }

        // reachable[j]: `held[..<i]` is `reference[..<j]` with only losable
        // characters lost or stood in for, one row of `i` at a time.
        var reachable = [Bool](repeating: false, count: reference.count + 1)
        reachable[0] = true
        for j in 1...reference.count {
            reachable[j] = reachable[j - 1] && reference[j - 1].isLosable
        }
        for unit in held {
            var next = [Bool](repeating: false, count: reference.count + 1)
            for j in 1...reference.count {
                let candidate = reference[j - 1]
                if candidate.isLosable, next[j - 1] {
                    next[j] = true
                } else if reachable[j - 1] {
                    next[j] = unit.isPlaceholder
                        ? candidate.isLosable
                        : unit.character == candidate.character
                }
            }
            reachable = next
        }
        return reachable[reference.count]
    }

    /// Whether `held`, character for character `reference`, has no space
    /// where `reference` has one between two letters.
    private static func runsWordsTogether(_ held: [Unit], of reference: [Unit]) -> Bool {
        guard held.count == reference.count else { return false }
        return reference.indices.dropFirst().contains { index in
            reference[index].followsSpace && !held[index].followsSpace
                && reference[index - 1].character.isLetter && reference[index].character.isLetter
        }
    }

    /// One comparable character, with what it came from.
    private struct Unit {
        let character: Character
        /// It came from a non-ASCII character, which a PDF font can lose.
        let isLosable: Bool
        /// U+FFFD or U+0000: the extraction marking a glyph it could not map.
        let isPlaceholder: Bool
        /// Whitespace stood between it and the character before it.
        var followsSpace = false
    }

    /// Whitespace and format characters dropped; each character's
    /// compatibility form, with dashes and quotes folded to ASCII.
    private static func units(of text: String) -> [Unit] {
        var units: [Unit] = []
        var pendingSpace = false
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.value == 0xFFFD || scalar.value == 0 {
                units.append(Unit(character: "\u{FFFD}", isLosable: false, isPlaceholder: true, followsSpace: pendingSpace))
                pendingSpace = false
                continue
            }
            if scalar.properties.isWhitespace {
                pendingSpace = !units.isEmpty
                continue
            }
            if scalar.properties.generalCategory == .format {
                continue
            }
            let losable = !scalar.isASCII
            for folded in String(Character(scalar)).precomposedStringWithCompatibilityMapping.unicodeScalars {
                if folded.properties.isWhitespace || folded.properties.generalCategory == .format {
                    continue
                }
                units.append(Unit(
                    character: Character(typographic(folded)),
                    isLosable: losable,
                    isPlaceholder: false,
                    followsSpace: pendingSpace
                ))
                pendingSpace = false
            }
        }
        return units
    }

    private static func typographic(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0x2010...0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D:
            return "-"
        case 0x2018, 0x2019, 0x201A, 0x201B, 0x2032, 0x2035:
            return "'"
        case 0x201C, 0x201D, 0x201E, 0x201F, 0x2033, 0x2036:
            return "\""
        default:
            return scalar
        }
    }
}
