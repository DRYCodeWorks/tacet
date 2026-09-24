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
        var out = String.UnicodeScalarView()
        var sentenceBoundaryPending = false
        for scalar in raw.unicodeScalars {
            let value = isControl(scalar) || isLineSeparator(scalar) ? " " : scalar
            if value.properties.isWhitespace {
                sentenceBoundaryPending = false
            } else if sentenceBoundaryPending && value.properties.isUppercase {
                out.append(" ")
            }
            out.append(value)
            sentenceBoundaryPending = isSentenceEnd(value)
                || (sentenceBoundaryPending && isClosingQuoteOrBracket(value))
        }
        return String(out)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func isSentenceEnd(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "." || scalar == "!" || scalar == "?"
    }

    private static func isClosingQuoteOrBracket(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\"" || scalar == "'" || scalar == "”" || scalar == "’"
            || scalar == "»" || scalar == ")" || scalar == "]" || scalar == "}"
    }
}
