/// Transcript sanitisation — a faithful port of `src/tacet/sanitize.py`.
///
/// Dictation never wants a literal newline. Collapsing whitespace is what
/// makes it structurally impossible for a transcript to submit a prompt
/// early, rather than relying on bracketed paste to save us.
///
/// Control characters (C0 0x00-0x08,0x0B,0x0C,0x0E-0x1F, 0x7F and C1
/// 0x80-0x9F, which includes the 8-bit single-byte equivalents of ESC-prefixed
/// sequences like CSI/OSC/DCS) are replaced with a space rather than deleted,
/// so a stray control character cannot smuggle an escape sequence into the
/// receiving application. Substituting instead of deleting also means two
/// words separated only by a control character become two space-separated
/// words after collapsing, not one fused word.
public enum Sanitize {
    /// Roughly Python's `[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]`.
    static func isControl(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v <= 0x08 { return true }
        if v == 0x0B || v == 0x0C { return true }
        if (0x0E...0x1F).contains(v) { return true }
        if (0x7F...0x9F).contains(v) { return true }
        return false
    }

    /// Unicode line/paragraph separators, also hostile to a terminal.
    static func isLineSeparator(_ s: Unicode.Scalar) -> Bool {
        s.value == 0x2028 || s.value == 0x2029
    }

    /// Replace control characters and Unicode line separators with a space,
    /// insert spacing after `.?!` before uppercase text, collapse whitespace,
    /// and trim.
    public static func sanitize(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { isControl($0) || isLineSeparator($0) ? " " : $0 }
        var out = String.UnicodeScalarView()
        var boundary: Int?  // index of `.?!` not yet followed by whitespace
        for (i, scalar) in scalars.enumerated() {
            if scalar.properties.isWhitespace {
                boundary = nil
            } else if let b = boundary, scalar.properties.isUppercase,
                      isSentenceBreak(scalars, punctuation: b, nextWord: i) {
                out.append(" ")
            }
            out.append(scalar)
            if isSentenceEnd(scalar) {
                boundary = i
            } else if !isClosingQuoteOrBracket(scalar) {
                boundary = nil
            }
        }
        return String(out)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Whether the uppercase word at `nextWord`, written straight after the
    /// punctuation at `punctuation`, starts a new sentence.
    ///
    /// Whisper sometimes drops the space between sentences ("done.Then"), but
    /// it also writes names and initialisms that look the same: "ASP.NET",
    /// "U.S.". Splitting those corrupts words it got right, so two shapes are
    /// left alone. A rare missed repair ("done.API") is the price (#31).
    static func isSentenceBreak(_ s: [Unicode.Scalar], punctuation p: Int, nextWord n: Int) -> Bool {
        // An initialism: the period follows a single letter ("U.S.", "e.g.").
        let singleLetterBefore = p >= 1 && s[p - 1].properties.isAlphabetic
            && (p < 2 || !s[p - 2].properties.isAlphabetic)
        if s[p] == "." && singleLetterBefore { return false }
        // A dotted all-caps name: the next word is capitals only (".NET", ".JS").
        let word = s[n...].prefix(while: { $0.properties.isAlphabetic })
        let allCaps = word.count >= 2 && !word.contains(where: { $0.properties.isLowercase })
        return !allCaps
    }

    private static func isSentenceEnd(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "." || scalar == "!" || scalar == "?"
    }

    private static func isClosingQuoteOrBracket(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\"" || scalar == "'" || scalar == "”" || scalar == "’"
            || scalar == "»" || scalar == ")" || scalar == "]" || scalar == "}"
    }
}
