import Foundation

/// A passage selected over an equation carries the TeX the reply was written
/// in — `$$\frac{\Delta G_{\mathrm{H^+}}}{F}$$` — because that is what the model
/// reads. Drawn back in a native `Text` (the composer's pending quote, the
/// learner's bubble, a side chat's question) it showed the learner backslashes
/// and braces where the reply had shown them an equation. This turns that
/// markup into the closest plain text: `ΔG_H⁺/F`. It is a preview, not a
/// renderer: the model still receives the passage exactly as selected, and
/// prose without TeX passes through untouched.
extension String {
    /// The receiver with TeX markup folded into readable text. Returns the
    /// receiver unchanged when nothing in it looks like TeX.
    func foldingTeXForPreview() -> String {
        guard ReadableMath.containsTeX(self) else { return self }
        return ReadableMath.render(self)
    }
}

extension String {
    /// A card's front or back as a `Text` draws it: math spans folded, then
    /// the inline Markdown a card may carry drawn rather than shown as marks
    /// — a `[Figure 4f](foreverlm://source/…?page=6)` link becomes the words
    /// "Figure 4f", clickable, and `**Donor origin:**` becomes bold. Line
    /// breaks are kept. Text with no Markdown mark comes back as it was.
    func cardFaceText() -> AttributedString {
        let folded = foldingMathSpans()
        guard folded.contains(where: { $0 == "[" || $0 == "*" || $0 == "_" || $0 == "`" }) else {
            return AttributedString(folded)
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: folded, options: options)) ?? AttributedString(folded)
    }
}

extension String {
    /// The receiver with each math span (`\(…\)`, `\[…\]`, `$$…$$`) folded
    /// into readable text and everything around the spans untouched, line
    /// breaks included. A card's front, back and why are prose with a formula
    /// here and there, so unlike `foldingTeXForPreview` the prose is never
    /// re-flowed. An unclosed opener is left as written.
    func foldingMathSpans() -> String {
        guard contains("$$") || contains("\\(") || contains("\\[") else { return self }
        let openers: [(open: String, close: String)] = [("$$", "$$"), ("\\(", "\\)"), ("\\[", "\\]")]
        var result = ""
        var rest = self[...]
        while true {
            let next = openers
                .compactMap { pair -> (range: Range<String.Index>, close: String)? in
                    rest.range(of: pair.open).map { ($0, pair.close) }
                }
                .min { $0.range.lowerBound < $1.range.lowerBound }
            guard let next, let close = rest.range(of: next.close, range: next.range.upperBound..<rest.endIndex) else {
                result += rest
                return result
            }
            result += rest[..<next.range.lowerBound]
            result += ReadableMath.render(String(rest[next.range.lowerBound..<close.upperBound]))
            rest = rest[close.upperBound...]
        }
    }
}

enum ReadableMath {
    /// Math delimiters or a backslash command: the two ways TeX shows up in a
    /// passage. A lone `$5` in prose is neither.
    static func containsTeX(_ text: String) -> Bool {
        if text.contains("$$") || text.contains("\\(") || text.contains("\\[") { return true }
        let scalars = Array(text.unicodeScalars)
        for index in scalars.indices.dropLast() where scalars[index] == "\\" {
            if CharacterSet.letters.contains(scalars[index + 1]) { return true }
        }
        return false
    }

    static func render(_ text: String) -> String {
        var parser = Parser(Array(text.unicodeScalars))
        var rendered = ""
        for character in parser.parseSequence(until: nil) {
            if spacedOperators.contains(character) {
                if let last = rendered.last, !last.isWhitespace { rendered.append(" ") }
                rendered.append(character)
                rendered.append(" ")
            } else {
                rendered.append(character)
            }
        }
        return rendered
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Relations and arrows: `a≈b` and `A→B` read as `a ≈ b` and `A → B`.
    /// `+` and `-` are left as the passage spaced them, because `H^+` and `-D`
    /// are signs as often as operations.
    private static let spacedOperators: Set<Character> = [
        "=", "≈", "≠", "≤", "≥", "≡", "∝", "∼", "≃", "≪", "≫", "→", "←", "↔", "⇒", "⇐", "⇔", "↦", "⇌", "⟶", "·", "×",
    ]

    // MARK: - Tables

    /// Commands that stand for one symbol.
    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ",
        "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "circ": "∘",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈",
        "sim": "∼", "simeq": "≃", "equiv": "≡", "propto": "∝", "ll": "≪", "gg": "≫",
        "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏", "int": "∫",
        "oint": "∮", "in": "∈", "notin": "∉", "subset": "⊂", "supset": "⊃", "cup": "∪", "cap": "∩",
        "forall": "∀", "exists": "∃", "emptyset": "∅", "neg": "¬", "lnot": "¬", "land": "∧", "lor": "∨",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "Leftrightarrow": "⇔", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
        "rightleftharpoons": "⇌", "longrightarrow": "⟶", "implies": "⇒", "iff": "⇔",
        "ldots": "…", "cdots": "⋯", "dots": "…", "prime": "′", "degree": "°", "angle": "∠",
        "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "langle": "⟨", "rangle": "⟩",
        "lbrace": "{", "rbrace": "}", "lvert": "|", "rvert": "|", "vert": "|", "mid": "|",
        "colon": ":", "quad": " ", "qquad": "  ", "space": " ", "enspace": " ", "thinspace": " ",
    ]

    /// Commands whose one braced argument is the text to show.
    private static let wrappers: Set<String> = [
        "mathrm", "mathit", "mathbf", "mathsf", "mathtt", "mathcal", "mathbb", "mathfrak", "mathnormal",
        "text", "textrm", "textit", "textbf", "textsf", "texttt", "textnormal", "emph",
        "operatorname", "mbox", "hbox", "boldsymbol", "bm", "vec", "hat", "bar", "tilde", "dot",
        "ddot", "overline", "underline", "label", "tag",
    ]

    /// Commands that vanish, taking no argument with them.
    private static let silent: Set<String> = [
        "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
        "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "nonumber", "limits",
        "nolimits", "rm", "it", "bf", "boldmath", "unboldmath",
    ]

    /// Shared with `InlineMarkup` below, whose `<sup>` and `<sub>` are the same
    /// scripts written as tags.
    fileprivate static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "∘": "°", "°": "°",
    ]

    fileprivate static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ", "h": "ₕ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
        "p": "ₚ", "s": "ₛ", "t": "ₜ", "i": "ᵢ", "j": "ⱼ", "r": "ᵣ", "u": "ᵤ", "v": "ᵥ",
    ]

    // MARK: - Parser

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index >= scalars.count }

        mutating func parseSequence(until terminator: Unicode.Scalar?) -> String {
            var output = ""
            while !atEnd {
                let scalar = scalars[index]
                if let terminator, scalar == terminator {
                    index += 1
                    return output
                }
                switch scalar {
                case "\\":
                    output += parseCommand()
                case "{":
                    index += 1
                    output += parseSequence(until: "}")
                case "}":
                    // An unbalanced close: drop it rather than echo markup.
                    index += 1
                case "$":
                    index += 1
                    if !atEnd, scalars[index] == "$" { index += 1 }
                case "^":
                    index += 1
                    output += script(parseArgument(), table: superscripts, marker: "^")
                case "_":
                    index += 1
                    output += script(parseArgument(), table: subscripts, marker: "_")
                case "~":
                    index += 1
                    output += " "
                default:
                    output.unicodeScalars.append(scalar)
                    index += 1
                }
            }
            return output
        }

        /// The receiver sits just past a backslash.
        private mutating func parseCommand() -> String {
            index += 1
            guard !atEnd else { return "" }
            let first = scalars[index]
            guard CharacterSet.letters.contains(first) else {
                // `\(`, `\[`, `\)`, `\]` delimit math; `\,` `\;` `\!` `\ ` space
                // it; `\\` breaks a line; `\{` `\%` `\$` `\&` `\_` escape.
                index += 1
                switch first {
                case "(", ")", "[", "]": return ""
                case ",", ";", ":", "!", " ", "\n": return " "
                case "\\": return " "
                default: return String(first)
                }
            }
            var name = ""
            while !atEnd, CharacterSet.letters.contains(scalars[index]) {
                name.unicodeScalars.append(scalars[index])
                index += 1
            }
            // `\Delta G` is ΔG: the space after a symbol command is TeX's
            // separator, not a word gap. Before an operator it is a gap —
            // `\psi - x` stays `ψ - x`.
            if let symbol = symbols[name] {
                skipSeparatorSpaces()
                return symbol
            }
            switch name {
            case "frac", "dfrac", "tfrac":
                let numerator = parseArgument()
                let denominator = parseArgument()
                return "\(ReadableMath.fractionPart(numerator))/\(ReadableMath.fractionPart(denominator))"
            case "sqrt":
                skipOptionalArgument()
                let radicand = parseArgument()
                return radicand.contains(" ") || radicand.count > 3 ? "√(\(radicand))" : "√\(radicand)"
            case "begin", "end":
                _ = parseArgument()
                return " "
            default:
                break
            }
            if silent.contains(name) { skipSpaces(); return "" }
            if wrappers.contains(name) { return parseArgument() }
            // A command this table does not know: show its name, which reads
            // better than swallowing `\ln` or `\exp` whole, and keep the space
            // after it so `\ln K` stays two words.
            return name
        }

        /// One braced group, one command, or one scalar, as `^`, `_`, `\frac`
        /// and friends take it.
        private mutating func parseArgument() -> String {
            skipSpaces()
            guard !atEnd else { return "" }
            let scalar = scalars[index]
            if scalar == "{" {
                index += 1
                return parseSequence(until: "}")
            }
            if scalar == "\\" { return parseCommand() }
            index += 1
            return String(scalar)
        }

        private mutating func skipOptionalArgument() {
            skipSpaces()
            guard !atEnd, scalars[index] == "[" else { return }
            index += 1
            _ = parseSequence(until: "]")
        }

        private mutating func skipSpaces() {
            while !atEnd, scalars[index] == " " { index += 1 }
        }

        /// Spaces that only separate a command from the letter, digit or
        /// command after it.
        private mutating func skipSeparatorSpaces() {
            var lookahead = index
            while lookahead < scalars.count, scalars[lookahead] == " " { lookahead += 1 }
            guard lookahead > index, lookahead < scalars.count else { return }
            let next = scalars[lookahead]
            if next == "\\" || CharacterSet.alphanumerics.contains(next) { index = lookahead }
        }

        private func script(_ argument: String, table: [Character: Character], marker: Character) -> String {
            guard !argument.isEmpty else { return "" }
            let converted = argument.compactMap { table[$0] }
            if converted.count == argument.count { return String(converted) }
            // `e^{FE/RT}` must not read as `e^FE/RT`: a script that cannot be
            // set small and carries an operator keeps its grouping.
            if argument.contains(where: { "/+-−=".contains($0) }) { return "\(marker)(\(argument))" }
            return "\(marker)\(argument)"
        }
    }

    /// `(a+b)/2`, but `a/b`: parentheses only where a fraction's part would
    /// otherwise bleed into the slash. MathML's `<mfrac>` reads the same way.
    fileprivate static func fractionPart(_ part: String) -> String {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let binders: Set<Character> = [" ", "+", "-", "−", "±", "/", "·", "×", "=", "→"]
        let interior = trimmed.dropFirst()
        return interior.contains(where: { binders.contains($0) }) ? "(\(trimmed))" : trimmed
    }
}

// MARK: - Inline markup

extension String {
    /// The receiver with the inline markup a scholarly catalog writes into a
    /// title folded into the closest plain text.
    ///
    /// Crossref, OpenAlex and a publisher's `citation_title` hand over
    /// `Respiratory chain linked H<sub>2</sub>O<sub>2</sub> production` and
    /// `ATP‐sensitive K<sup>+</sup> channel`, and every surface draws a title
    /// as text — a sidebar row, the chat's Sources list, an MCP answer — so the
    /// tags showed as tags. A script becomes Unicode where every character has
    /// a form (`H₂O₂`, `K⁺`, `Ca²⁺`) and reads inline where one does not
    /// (`K<sub>ATP</sub>` is `KATP`); styling (`<i>`, `<b>`, small caps) keeps
    /// its words; MathML reads as the formula it draws.
    ///
    /// Only a tag this vocabulary knows, closed by its own end tag, is markup.
    /// Anything else is text and passes through as written: `Zara <> Alan`,
    /// `p < 0.05`, a web page's `The <dialog> element` or `When to use <em>`.
    func foldingInlineMarkup() -> String {
        guard contains("<") else { return self }
        return InlineMarkup.fold(self)
    }
}

enum InlineMarkup {
    static func fold(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var tags: [Tag] = []
        var index = 0
        while index < scalars.count {
            if scalars[index] == "<", let tag = tag(in: scalars, at: index) {
                tags.append(tag)
                index = tag.range.upperBound
            } else {
                index += 1
            }
        }

        // An open tag pairs with the nearest later close of its name, and the
        // opens it encloses that never closed are text after all, as is a
        // close with nothing to pair.
        var closeOf: [Int: Int] = [:]
        var unclosed: [Int] = []
        for (position, tag) in tags.enumerated() {
            switch tag.kind {
            case .open:
                unclosed.append(position)
            case .close:
                if let depth = unclosed.lastIndex(where: { tags[$0].name == tag.name }) {
                    closeOf[unclosed[depth]] = position
                    unclosed.removeSubrange(depth...)
                }
            case .empty:
                break
            }
        }
        guard !closeOf.isEmpty || tags.contains(where: { $0.kind == .empty }) else { return text }
        let pairedCloses = Set(closeOf.values)

        var frames: [(name: String, children: [Node])] = [("", [])]
        var cursor = 0
        func appendText(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            frames[frames.count - 1].children.append(.text(string(scalars[range])))
        }
        for (position, tag) in tags.enumerated() {
            appendText(cursor..<tag.range.lowerBound)
            cursor = tag.range.upperBound
            if tag.kind == .open, closeOf[position] != nil {
                frames.append((tag.name, []))
            } else if tag.kind == .close, pairedCloses.contains(position) {
                let element = frames.removeLast()
                frames[frames.count - 1].children.append(.element(element.name, element.children))
            } else if tag.kind == .empty {
                frames[frames.count - 1].children.append(.element(tag.name, []))
            } else {
                appendText(tag.range)
            }
        }
        appendText(cursor..<scalars.count)

        return render(frames[0].children, inMath: false)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    // MARK: Vocabulary

    private enum Role {
        /// HTML and JATS styling: the words stay, the look goes.
        case styling
        case sub
        case sup
        /// `mi`, `mn`, `mo`, `mtext`: the token's text.
        case mathToken
        /// `math`, `mrow` and the other MathML containers: the children in order.
        case mathGroup
        case mathSubscript
        case mathSuperscript
        case mathSubSuperscript
        case mathMultiscripts
        case mathFraction
        case mathSquareRoot
        case mathRoot
        /// `mover`, `munder`, `munderover`: the base; the accent or limit goes.
        case mathBase
        case space
        /// Drawn as nothing: an annotation repeating the formula as TeX, a
        /// phantom, a footnote marker.
        case hidden
        /// JATS `<alternatives>`: one rendering of a formula, MathML first.
        case alternatives
        /// JATS `<tex-math>`: read through the TeX fold.
        case tex
    }

    /// Local names, after any namespace prefix (`mml:`, `jats:`), lower-cased.
    private static let roles: [String: Role] = {
        var roles: [String: Role] = [
            "sub": .sub,
            // Scopus's and Elsevier's name for a subscript.
            "inf": .sub,
            "sup": .sup,
            "xref": .hidden,
            "alternatives": .alternatives,
            "tex-math": .tex,
            "msub": .mathSubscript,
            "msup": .mathSuperscript,
            "msubsup": .mathSubSuperscript,
            "mmultiscripts": .mathMultiscripts,
            "mfrac": .mathFraction,
            "msqrt": .mathSquareRoot,
            "mroot": .mathRoot,
            "mover": .mathBase,
            "munder": .mathBase,
            "munderover": .mathBase,
            "mspace": .space,
        ]
        for name in [
            "i", "b", "em", "strong", "u", "s", "strike", "span", "font", "small", "big", "tt", "code",
            "sc", "scp", "italic", "bold", "underline", "monospace", "sans-serif", "roman", "overline",
            "styled-content", "named-content", "inline-formula", "a", "ext-link", "abbr", "cite", "mark", "var",
        ] {
            roles[name] = .styling
        }
        for name in ["mi", "mn", "mo", "mtext", "ms"] {
            roles[name] = .mathToken
        }
        for name in [
            "math", "mrow", "mstyle", "mpadded", "menclose", "mfenced", "merror", "maction", "semantics",
            "mtable", "mtr", "mtd", "mlabeledtr", "mglyph", "mstack", "msrow", "msgroup", "mlongdiv",
            "mscarries", "mscarry", "msline", "maligngroup", "malignmark",
        ] {
            roles[name] = .mathGroup
        }
        for name in ["annotation", "annotation-xml", "mphantom", "none", "mprescripts"] {
            roles[name] = .hidden
        }
        return roles
    }()

    /// Dashes a script writes for a minus sign; `Cl<sup>–</sup>` is `Cl⁻`.
    private static let minusSigns: Set<Character> = ["‐", "‑", "–"]

    // MARK: Tags

    private struct Tag {
        enum Kind { case open, close, empty }
        let kind: Kind
        let name: String
        /// From the `<` through the `>`, in the text's scalars.
        let range: Range<Int>
    }

    /// The tag that starts at `start`, a `<`, when it is one the vocabulary
    /// knows. Attributes run to the first `>` outside quotes; a `<` before it,
    /// or the end of the text, means this was never a tag.
    private static func tag(in scalars: [Unicode.Scalar], at start: Int) -> Tag? {
        var index = start + 1
        var kind = Tag.Kind.open
        if index < scalars.count, scalars[index] == "/" {
            kind = .close
            index += 1
        }
        let nameStart = index
        guard nameStart < scalars.count, isASCIILetter(scalars[nameStart]) else { return nil }
        while index < scalars.count, isNameScalar(scalars[index]) { index += 1 }
        var name = string(scalars[nameStart..<index]).lowercased()
        if let colon = name.lastIndex(of: ":") {
            name = String(name[name.index(after: colon)...])
        }
        guard roles[name] != nil, index < scalars.count else { return nil }
        let afterName = scalars[index]
        guard afterName == ">" || afterName == "/" || afterName.properties.isWhitespace else { return nil }

        var quote: Unicode.Scalar?
        var lastSignificant: Unicode.Scalar?
        while index < scalars.count {
            let scalar = scalars[index]
            if let open = quote {
                if scalar == open { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == ">" {
                if kind == .close {
                    // `</sub>` carries nothing after its name.
                    guard lastSignificant == nil else { return nil }
                } else if lastSignificant == "/" {
                    kind = .empty
                }
                return Tag(kind: kind, name: name, range: start..<(index + 1))
            } else if scalar == "<" {
                return nil
            }
            if !scalar.properties.isWhitespace { lastSignificant = scalar }
            index += 1
        }
        return nil
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || (0x30...0x39).contains(scalar.value)
            || scalar == "-" || scalar == "_" || scalar == ":" || scalar == "."
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var result = ""
        result.unicodeScalars.append(contentsOf: scalars)
        return result
    }

    // MARK: Rendering

    private indirect enum Node {
        case text(String)
        case element(String, [Node])
    }

    private static func render(_ nodes: [Node], inMath: Bool) -> String {
        nodes.map { render($0, inMath: inMath) }.joined()
    }

    private static func render(_ node: Node, inMath: Bool) -> String {
        switch node {
        case .text(let text):
            // Between MathML elements, whitespace is layout, not content.
            return inMath && text.allSatisfy(\.isWhitespace) ? "" : text
        case .element(let name, let children):
            guard let role = roles[name] else { return render(children, inMath: inMath) }
            switch role {
            case .styling:
                return render(children, inMath: inMath)
            case .sub:
                return script(render(children, inMath: inMath), table: ReadableMath.subscripts)
            case .sup:
                return script(render(children, inMath: inMath), table: ReadableMath.superscripts)
            case .mathToken:
                return render(children, inMath: true).trimmingCharacters(in: .whitespacesAndNewlines)
            case .mathGroup:
                return render(children, inMath: true)
            case .mathSubscript, .mathSuperscript, .mathSubSuperscript:
                let parts = mathArguments(children)
                guard let base = parts.first else { return "" }
                let scripts = parts.dropFirst().prefix(role == .mathSubSuperscript ? 2 : 1)
                return scripts.enumerated().reduce(base) { result, entry in
                    let lowered = role == .mathSubscript || (role == .mathSubSuperscript && entry.offset == 0)
                    return result + script(entry.element, table: lowered ? ReadableMath.subscripts : ReadableMath.superscripts)
                }
            case .mathMultiscripts:
                // The base, then subscript–superscript pairs; after
                // `<mprescripts/>`, the pairs written before the base, the way
                // an isotope's mass number is.
                var post: [String] = []
                var pre: [String] = []
                var beforeBase = false
                for child in children {
                    if case .text(let text) = child, text.allSatisfy(\.isWhitespace) { continue }
                    if case .element(let childName, _) = child, childName == "mprescripts" {
                        beforeBase = true
                        continue
                    }
                    let rendered = render(child, inMath: true)
                    if beforeBase { pre.append(rendered) } else { post.append(rendered) }
                }
                func pairs(_ values: ArraySlice<String>) -> String {
                    values.enumerated().map { offset, value in
                        script(value, table: offset.isMultiple(of: 2) ? ReadableMath.subscripts : ReadableMath.superscripts)
                    }.joined()
                }
                return pairs(pre[...]) + (post.first ?? "") + pairs(post.dropFirst())
            case .mathFraction:
                let parts = mathArguments(children)
                guard parts.count >= 2 else { return parts.joined() }
                return "\(ReadableMath.fractionPart(parts[0]))/\(ReadableMath.fractionPart(parts[1]))"
            case .mathSquareRoot:
                return radical(render(children, inMath: true), index: "")
            case .mathRoot:
                let parts = mathArguments(children)
                guard let radicand = parts.first else { return "" }
                return radical(radicand, index: parts.count > 1 ? script(parts[1], table: ReadableMath.superscripts) : "")
            case .mathBase:
                return mathArguments(children).first ?? ""
            case .space:
                return " "
            case .hidden:
                return ""
            case .alternatives:
                let elements = children.compactMap { child -> Node? in
                    if case .element = child { return child }
                    return nil
                }
                func named(_ wanted: String) -> Node? {
                    elements.first { element in
                        if case .element(let elementName, _) = element { return elementName == wanted }
                        return false
                    }
                }
                guard let chosen = named("math") ?? named("tex-math") ?? elements.first else {
                    return render(children, inMath: inMath)
                }
                return render(chosen, inMath: inMath)
            case .tex:
                return readableTeX(render(children, inMath: false))
            }
        }
    }

    /// A MathML element's arguments in order, the whitespace between them dropped.
    private static func mathArguments(_ children: [Node]) -> [String] {
        children.compactMap { child in
            if case .text(let text) = child, text.allSatisfy(\.isWhitespace) { return nil }
            return render(child, inMath: true)
        }
    }

    /// A script in Unicode when every character has a form, and inline
    /// otherwise: `H₂O₂` and `Ca²⁺`, but `KATP` rather than half a subscript.
    private static func script(_ text: String, table: [Character: Character]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let converted = trimmed.compactMap { table[minusSigns.contains($0) ? "−" : $0] }
        return converted.count == trimmed.count ? String(converted) : trimmed
    }

    private static func radical(_ radicand: String, index: String) -> String {
        index + "√" + (radicand.count > 1 ? "(\(radicand))" : radicand)
    }

    /// JATS often wraps a `<tex-math>` formula in a whole LaTeX document; only
    /// the body is the formula.
    private static func readableTeX(_ tex: String) -> String {
        var formula = tex
        if let begin = formula.range(of: "\\begin{document}"),
           let end = formula.range(of: "\\end{document}", range: begin.upperBound..<formula.endIndex) {
            formula = String(formula[begin.upperBound..<end.lowerBound])
        }
        return ReadableMath.render(formula)
    }
}
