import Foundation

/// A notebook's title as its card shows it: a leading emoji is the card's
/// icon ("🧬 Mitochondria" reads Mitochondria beside a 🧬), the rest its
/// title. A title that is only an emoji stays whole. A notebook has no icon
/// field, so one whose title brings no emoji is drawn with the emoji its
/// words choose (`displayIcon`, `NotebookDefaultEmoji`).
struct NotebookTitle: Equatable, Sendable {
    /// The title's own leading emoji; nil when it has none.
    let icon: String?
    let text: String

    init(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, Self.isEmoji(first) {
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty {
                icon = String(first)
                text = rest
                return
            }
        }
        icon = nil
        text = trimmed
    }

    /// What every surface draws as the notebook's icon: the title's own
    /// emoji, else the one its words choose.
    var displayIcon: String {
        icon ?? NotebookDefaultEmoji.emoji(for: text)
    }

    /// A character drawn as an emoji: one shown as a picture by default, or
    /// one made so by a variation selector or a sequence. A digit, # or ©
    /// alone is text.
    static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        return first.properties.isEmoji && character.unicodeScalars.count > 1
    }
}

/// The soft colour a notebook's emoji is drawn on in the Space's list, as
/// NotebookLM's are (product owner, 2026-10-02: "this can also look nicer and more
/// like notebooklm"): one of eight hues, light in light mode and deep in dark
/// mode, chosen by a 32-bit FNV-1a hash of the notebook's id, so a notebook
/// keeps its colour through renames and on every device. The web's twin is
/// `notebookTintIndex` in library-notebooks.js; both run the `tints` cases of
/// docs-site/website/test/notebook-emoji-vectors.json.
enum NotebookTint {
    /// Blue, green, yellow, red, purple, cyan, orange, pink, as 0xRRGGBB.
    static let light: [UInt32] = [0xE8F0FE, 0xE6F4EA, 0xFEF7E0, 0xFCE8E6, 0xF3E8FD, 0xE4F7FB, 0xFEEFE3, 0xFDE7F3]
    static let dark: [UInt32] = [0x1F2A3B, 0x1F3026, 0x33301D, 0x3A2524, 0x2D2540, 0x1C3136, 0x3A2B1E, 0x3A2230]

    static func index(for notebookID: String) -> Int {
        Int(NotebookDefaultEmoji.fnv1a(Array(notebookID.utf8)) % UInt32(light.count))
    }
}

/// The emoji a notebook is drawn with when its title brings none (product owner,
/// 2026-10-02: "make sure that either emojis or nice ai generated images are
/// created for notebooks by default to make it look a bit more cheerful").
/// A pure function of the title, so nothing is written, every device draws
/// the same one, and typing an emoji at the start of the name replaces it.
/// The web's twin is `defaultNotebookEmoji` in library-notebooks.js; both
/// run docs-site/website/test/notebook-emoji-vectors.json.
///
/// The title is lowercased (a final ς read as σ), decomposed with its
/// combining accents (U+0300–U+036F) dropped, and split into words: runs of
/// letters and digits. The first entry of `table` with a keyword at the start
/// of one of those words wins, so specific topics come before broad ones
/// ("sleep" before "mito"). A keyword may span words ("in vivo"); one ending
/// in `=` must also end where a word ends ("ai=" takes "AI & ML", never
/// "aim"). A title no keyword matches gets one of `fallback` by an FNV-1a
/// hash of the UTF-8 of its words joined by single spaces.
enum NotebookDefaultEmoji {
    static func emoji(for title: String) -> String {
        let words = words(of: title)
        let joined = Array(words.joined(separator: " ").unicodeScalars)
        var starts: [Int] = []
        var offset = 0
        for word in words {
            starts.append(offset)
            offset += word.unicodeScalars.count + 1
        }
        for entry in table {
            for keyword in entry.keywords where matches(keyword, in: joined, wordStarts: starts) {
                return entry.emoji
            }
        }
        let hash = fnv1a(Array(words.joined(separator: " ").utf8))
        return fallback[Int(hash % UInt32(fallback.count))]
    }

    /// The title's words, as the table reads them.
    static func words(of title: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        let lowered = title.lowercased().replacingOccurrences(of: "\u{03C2}", with: "\u{03C3}")
        for scalar in lowered.decomposedStringWithCanonicalMapping.unicodeScalars {
            if (0x300...0x36F).contains(scalar.value) { continue }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                current.append(scalar)
            default:
                if !current.isEmpty {
                    words.append(String(current))
                    current = String.UnicodeScalarView()
                }
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }

    private static func matches(_ keyword: String, in joined: [Unicode.Scalar], wordStarts: [Int]) -> Bool {
        let wholeWord = keyword.hasSuffix("=")
        let needle = Array((wholeWord ? String(keyword.dropLast()) : keyword).unicodeScalars)
        for start in wordStarts where start + needle.count <= joined.count {
            guard Array(joined[start..<(start + needle.count)]) == needle else { continue }
            let end = start + needle.count
            if !wholeWord || end == joined.count || joined[end] == " " { return true }
        }
        return false
    }

    /// 32-bit FNV-1a.
    static func fnv1a(_ bytes: [UInt8]) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in bytes {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    /// Priority order: the first entry with a matching keyword wins. Specific
    /// topics (a disease, an organ, an organism) lead, then people, money and
    /// events, the physical sciences, technology, learning and everyday life,
    /// and broad science last.
    static let table: [(emoji: String, keywords: [String])] = [
        ("🦓", ["rare diseas", "rare disorder", "rare=", "orphan diseas"]),
        ("😴", ["sleep", "insomnia", "circadian", "melatonin", "dream", "nap="]),
        ("🧠", ["brain", "neuro", "alzheimer", "parkinson", "dementia", "cognit", "memory=", "memories", "conscious", "huntington", "autism", "adhd="]),
        ("💭", ["psycholog", "emotion", "mental", "anxiety", "depress", "mood="]),
        ("❤️", ["heart", "cardi", "blood pressure", "hypertension", "artery", "arteries", "vascular"]),
        ("🫁", ["lung", "hypoxi", "oxygen", "breath", "respirator", "pulmonar", "asthma", "altitude"]),
        ("🩸", ["blood", "hemato", "haemato", "anemi", "anaemi", "plasma="]),
        ("🦠", ["microb", "bacteri", "virus", "viral", "infect", "pathogen", "covid", "pandemic", "epidemi", "gut=", "probiotic", "antibiotic"]),
        ("🛡️", ["immun", "autoimmun", "antibod", "inflamm", "allerg"]),
        ("🎗️", ["cancer", "tumor", "tumour", "oncolog", "chemotherap", "leukemi", "leukaemi", "lymphoma", "melanoma", "carcinoma", "metasta"]),
        ("💉", ["vaccin", "transplant", "inject", "transfus", "insulin", "diabet"]),
        ("💊", ["drug", "pharma", "indication", "medication", "dosing", "dose=", "pill", "supplement", "nad=", "rapamycin", "metformin", "statin", "ozempic", "semaglutide", "glp 1", "glp1"]),
        ("🩺", ["diagnos", "clinic", "patient", "doctor", "physician", "symptom", "hospital", "nurse", "nursing", "biomarker", "stratif"]),
        ("🦴", ["bone", "osteo", "skelet", "joint=", "joints=", "arthritis", "spine", "spinal"]),
        ("🦷", ["tooth", "teeth", "dental", "dentist"]),
        ("👁️", ["eye=", "eyes=", "vision", "retina", "ophthalm", "sight="]),
        ("🤰", ["pregnan", "fertil", "ivf=", "obstetr", "prenatal", "maternal", "menopaus", "menstru"]),
        ("👶", ["baby", "babies", "infant", "toddler", "newborn", "parenting", "child", "kids=", "kid="]),
        ("🏃", ["running", "runner", "marathon", "endurance", "triathlon", "jogging"]),
        ("💪", ["exercis", "muscle", "fitness", "strength", "workout", "sport", "athlet", "gym=", "physical activity", "sarcopeni", "vo2"]),
        ("🧘", ["meditat", "mindful", "yoga", "stress", "wellbeing", "well being", "wellness", "relax"]),
        ("🔄", ["krebs", "tca=", "citric acid", "feedback loop"]),
        ("🔥", ["metabol", "thermogen", "fire=", "heat=", "burn", "obesity", "weight loss", "fat loss", "brown fat"]),
        ("🥗", ["nutrition", "nutrient", "diet", "food", "eating", "vegan", "vegetarian", "vitamin", "fasting", "calori", "keto", "meal"]),
        ("🍳", ["cook", "recipe", "kitchen", "baking", "bake=", "chef", "cuisine"]),
        ("☕", ["coffee", "tea=", "caffein", "espresso"]),
        ("🍷", ["wine", "beer", "alcohol", "cocktail"]),
        ("⏳", ["aging", "ageing", "age=", "longevity", "lifespan", "healthspan", "senescen", "rejuvenat", "geroscience", "gerontolog"]),
        ("🔋", ["bioenerget", "powerhouse", "atp=", "cristae", "crista=", "oxphos", "mitophag"]),
        ("⚡", ["bioelectric", "electric", "voltage", "ion channel", "membrane potential", "na k=", "sodium potassium"]),
        ("🧬", ["gene=", "genes=", "genom", "genetic", "dna=", "rna=", "mrna", "crispr", "sequenc", "epigen", "chromosom", "mutation", "proteom", "transcriptom", "omics", "heredit"]),
        ("🧩", ["systems biolog", "puzzle", "complex system", "network biolog"]),
        ("🧫", ["cell=", "cells=", "cellular", "stem cell", "organoid", "petri", "tissue", "mitosis", "mitotic", "cytolog"]),
        ("🪱", ["worm", "planaria", "planarian", "elegans", "regenerat", "two headed"]),
        ("🪰", ["fly=", "flies=", "drosophila", "insect"]),
        ("🐭", ["mouse", "mice", "rodent", "in vivo", "murine"]),
        ("🐟", ["fish", "zebrafish", "salmon"]),
        ("🦋", ["butterfl", "evolution", "darwin", "metamorph", "moth="]),
        ("🦕", ["dinosaur", "fossil", "paleont", "jurassic"]),
        ("🐾", ["animal", "pet=", "pets=", "dog=", "dogs=", "cat=", "cats=", "puppy", "kitten", "zoolog", "wildlife", "veterinar", "bird", "horse"]),
        ("🍄", ["mushroom", "fungi", "fungus", "fungal", "mycolog", "psilocybin", "psychedel"]),
        ("💰", ["investor", "investing", "investment", "invest=", "money", "financ", "funding", "fund=", "funds=", "fundrais", "venture", "vc=", "vcs=", "capital", "wealth", "budget", "tax=", "taxes", "pricing"]),
        ("📈", ["market", "stock", "trading", "econom", "growth", "sales", "revenue"]),
        ("♟️", ["strateg", "chess", "game theory", "tactic"]),
        ("🚀", ["startup", "start up", "launch", "rocket", "space=", "nasa", "mars=", "spacex", "aerospace", "astronaut", "moon="]),
        ("💼", ["business", "career", "job=", "jobs=", "interview", "management", "leadership", "company", "office", "consult", "hiring"]),
        ("🎤", ["conference", "talk=", "talks=", "keynote", "speech", "presentation", "pitch", "summit", "symposium"]),
        ("🎙️", ["podcast", "radio="]),
        ("🌋", ["geolog", "volcan", "earthquake", "seismic", "tectonic", "mineral"]),
        ("🌍", ["climate", "earth", "environment", "sustainab", "carbon", "geograph", "global", "world", "emission", "renewable"]),
        ("🪐", ["planet", "saturn", "jupiter", "solar system", "exoplanet"]),
        ("☀️", ["solar", "sun=", "sunlight", "summer"]),
        ("🔭", ["astronom", "astrophys", "cosmolog", "telescope", "galax", "universe", "star=", "stars=", "black hole", "cosmos", "nebula"]),
        ("⚛️", ["quantum", "physics", "atom", "particle", "nuclear", "relativity", "thermodynam"]),
        ("📐", ["math", "algebra", "calculus", "geometr", "probabilit", "theorem", "equation", "topolog", "number theory", "arithmetic"]),
        ("🧲", ["nmr=", "mri=", "magnet", "imaging", "spectroscop", "ultrasound", "x ray", "radiolog", "ct scan"]),
        ("🌊", ["ocean", "marine", "sea=", "seas=", "water", "river", "coral", "lake", "surf", "sailing", "beach"]),
        ("🌦️", ["weather", "meteorolog", "rain=", "storm", "season"]),
        ("🌱", ["plant", "botan", "garden", "seed", "agricultur", "farm", "crop", "photosynth", "soil", "permacultur", "ecolog"]),
        ("🌲", ["forest", "tree=", "trees=", "wood", "hiking", "camping", "outdoor"]),
        ("🤖", ["ai=", "artificial intelligence", "machine learning", "deep learning", "neural net", "llm", "gpt", "chatgpt", "claude=", "robot", "language model", "agentic", "ml="]),
        ("🔐", ["security", "privacy", "password", "encrypt", "cryptograph", "cyber", "hacking"]),
        ("🪙", ["crypto", "bitcoin", "blockchain", "ethereum", "web3", "defi="]),
        ("💻", ["code", "coding", "program", "software", "comput", "python", "javascript", "typescript", "swift=", "rust=", "algorithm", "bioinformat", "web dev", "app=", "apps=", "developer", "github", "linux", "database"]),
        ("📊", ["data=", "statistic", "analytics", "dashboard", "metric", "survey", "spreadsheet", "excel", "visualiz", "visualis"]),
        ("⚙️", ["engineer", "mechanic", "infrastructure", "devops", "automat", "manufactur", "hardware"]),
        ("🎓", ["course", "lecture", "class=", "classes=", "university", "degree", "phd=", "thesis", "exam", "school", "curriculum", "syllabus"]),
        ("📚", ["book", "reading", "literatur", "novel", "library"]),
        ("📄", ["paper", "preprint", "journal club", "manuscript", "publication"]),
        ("✍️", ["writ", "essay", "blog", "poem", "poetry", "journaling", "newsletter"]),
        ("🗣️", ["language", "linguist", "grammar", "vocab", "translat", "spanish", "french", "german", "dutch", "italian", "chinese", "japanese", "english"]),
        ("🏛️", ["history", "historic", "ancient", "roman", "greek", "empire", "politic", "govern", "museum", "civilization", "civilisation"]),
        ("⚖️", ["law=", "laws=", "legal", "justice", "court", "regulat", "ethic", "policy", "contract", "compliance"]),
        ("🕊️", ["peace", "relig", "spiritual", "faith", "theolog", "bible", "buddhis"]),
        ("🤔", ["philosoph", "logic", "thinking", "reasoning", "epistemolog"]),
        ("🎨", ["art=", "arts=", "design", "paint", "drawing", "illustrat", "creativ", "sketch", "color", "colour", "typograph"]),
        ("📷", ["photo", "camera"]),
        ("🎮", ["game", "gaming", "videogame"]),
        ("🎬", ["film", "movie", "cinema", "video", "youtube", "documentar", "animation"]),
        ("🎵", ["music", "song", "piano", "guitar", "singing", "compos", "melod"]),
        ("✈️", ["travel", "trip=", "trips=", "flight", "vacation", "holiday"]),
        ("🗺️", ["map=", "maps=", "atlas", "explor", "navigat", "landscape", "geospatial"]),
        ("🏠", ["home", "house", "apartment", "real estate", "renovat", "interior"]),
        ("👪", ["family", "relationship", "marriage", "wedding", "friend"]),
        ("🤝", ["team", "partner", "collaborat", "community", "network", "meeting", "standup", "stand up", "negotiat"]),
        ("🗓️", ["planning", "plan=", "schedule", "calendar", "agenda", "weekly", "daily", "routine"]),
        ("✅", ["todo", "to do", "task", "checklist", "habit", "productiv"]),
        ("🎯", ["goal", "target", "focus", "objective", "okr="]),
        ("💡", ["idea", "insight", "innovat", "invent", "inspiration"]),
        ("🔍", ["search", "investigat", "discover", "detective", "mystery"]),
        ("📰", ["news", "current events", "media", "journalism"]),
        ("🔋", ["mito", "battery", "batteries", "respiration"]),
        ("🧪", ["biotech", "biochem", "molecul", "compound", "reagent", "enzym", "lipid", "peptide", "antioxidant", "ros=", "redox"]),
        ("⚗️", ["chemistry", "chemical", "alchem", "catalys", "polymer"]),
        ("⚡", ["electro", "energy"]),
        ("🔬", ["microscop", "screen", "phenotyp", "assay", "lab=", "labs=", "laborator", "experiment", "histolog", "patholog", "science", "scientific", "research"]),
        ("🩺", ["medic", "health", "disease", "therap", "treatment", "surgery", "surgical"]),
        ("🧬", ["biolog", "bio="]),
    ]

    /// For a title no keyword matches, one of these by `fnv1a` of its words.
    static let fallback: [String] = ["📚", "✨", "🌱", "🌟", "💡", "🧭", "🔭", "🎯", "🪴", "🌈", "🍀", "🦋", "🌻", "🚀", "🧩", "🎨"]
}
