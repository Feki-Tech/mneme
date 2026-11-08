/// The 100 languages Whisper large-v3 recognises, keyed by the codes Whisper itself uses.
public enum WhisperLanguages {
    public static let names: [String: String] = [
        "af": "afrikaans", "am": "amharic", "ar": "arabic", "as": "assamese", "az": "azerbaijani",
        "ba": "bashkir", "be": "belarusian", "bg": "bulgarian", "bn": "bengali", "bo": "tibetan",
        "br": "breton", "bs": "bosnian", "ca": "catalan", "cs": "czech", "cy": "welsh",
        "da": "danish", "de": "german", "el": "greek", "en": "english", "es": "spanish",
        "et": "estonian", "eu": "basque", "fa": "persian", "fi": "finnish", "fo": "faroese",
        "fr": "french", "gl": "galician", "gu": "gujarati", "ha": "hausa", "haw": "hawaiian",
        "he": "hebrew", "hi": "hindi", "hr": "croatian", "ht": "haitian creole", "hu": "hungarian",
        "hy": "armenian", "id": "indonesian", "is": "icelandic", "it": "italian", "ja": "japanese",
        "jw": "javanese", "ka": "georgian", "kk": "kazakh", "km": "khmer", "kn": "kannada",
        "ko": "korean", "la": "latin", "lb": "luxembourgish", "ln": "lingala", "lo": "lao",
        "lt": "lithuanian", "lv": "latvian", "mg": "malagasy", "mi": "maori", "mk": "macedonian",
        "ml": "malayalam", "mn": "mongolian", "mr": "marathi", "ms": "malay", "mt": "maltese",
        "my": "myanmar", "ne": "nepali", "nl": "dutch", "nn": "nynorsk", "no": "norwegian",
        "oc": "occitan", "pa": "punjabi", "pl": "polish", "ps": "pashto", "pt": "portuguese",
        "ro": "romanian", "ru": "russian", "sa": "sanskrit", "sd": "sindhi", "si": "sinhala",
        "sk": "slovak", "sl": "slovenian", "sn": "shona", "so": "somali", "sq": "albanian",
        "sr": "serbian", "su": "sundanese", "sv": "swedish", "sw": "swahili", "ta": "tamil",
        "te": "telugu", "tg": "tajik", "th": "thai", "tk": "turkmen", "tl": "tagalog",
        "tr": "turkish", "tt": "tatar", "uk": "ukrainian", "ur": "urdu", "uz": "uzbek",
        "vi": "vietnamese", "yi": "yiddish", "yo": "yoruba", "yue": "cantonese", "zh": "chinese",
    ]

    /// ISO 639-2 and 639-3 codes, and legacy codes, mapped to Whisper's codes.
    static let aliases: [String: String] = [
        "afr": "af", "amh": "am", "ara": "ar", "arb": "ar", "asm": "as", "aze": "az", "bak": "ba",
        "bel": "be", "bul": "bg", "ben": "bn", "bod": "bo", "tib": "bo", "bre": "br", "bos": "bs",
        "cat": "ca", "ces": "cs", "cze": "cs", "cym": "cy", "wel": "cy", "dan": "da", "deu": "de",
        "ger": "de", "ell": "el", "gre": "el", "eng": "en", "spa": "es", "est": "et", "eus": "eu",
        "baq": "eu", "fas": "fa", "per": "fa", "pes": "fa", "fin": "fi", "fao": "fo", "fra": "fr",
        "fre": "fr", "glg": "gl", "guj": "gu", "hau": "ha", "heb": "he", "iw": "he", "hin": "hi",
        "hrv": "hr", "hat": "ht", "hun": "hu", "hye": "hy", "arm": "hy", "ind": "id", "in": "id",
        "isl": "is", "ice": "is", "ita": "it", "jpn": "ja", "jav": "jw", "jv": "jw", "kat": "ka",
        "geo": "ka", "kaz": "kk", "khm": "km", "kan": "kn", "kor": "ko", "lat": "la", "ltz": "lb",
        "lin": "ln", "lao": "lo", "lit": "lt", "lav": "lv", "mlg": "mg", "mri": "mi", "mao": "mi",
        "mkd": "mk", "mac": "mk", "mal": "ml", "mon": "mn", "mar": "mr", "msa": "ms", "may": "ms",
        "zsm": "ms", "mlt": "mt", "mya": "my", "bur": "my", "nep": "ne", "nld": "nl", "dut": "nl",
        "nno": "nn", "nor": "no", "nob": "no", "nb": "no", "oci": "oc", "pan": "pa", "pol": "pl",
        "pus": "ps", "por": "pt", "ron": "ro", "rum": "ro", "mo": "ro", "rus": "ru", "san": "sa",
        "snd": "sd", "sin": "si", "slk": "sk", "slo": "sk", "slv": "sl", "sna": "sn", "som": "so",
        "sqi": "sq", "alb": "sq", "srp": "sr", "sun": "su", "swe": "sv", "swa": "sw", "swh": "sw",
        "tam": "ta", "tel": "te", "tgk": "tg", "tha": "th", "tuk": "tk", "tgl": "tl", "fil": "tl",
        "tur": "tr", "tat": "tt", "ukr": "uk", "urd": "ur", "uzb": "uz", "vie": "vi", "yid": "yi",
        "yor": "yo", "zho": "zh", "chi": "zh", "cmn": "zh",
    ]

    /// Alternative English names for languages.
    static let alternativeNames: [String: String] = [
        "burmese": "my", "castilian": "es", "farsi": "fa", "filipino": "tl", "flemish": "nl",
        "haitian": "ht", "letzeburgesch": "lb", "mandarin": "zh", "moldavian": "ro", "moldovan": "ro",
        "panjabi": "pa", "pushto": "ps", "sinhalese": "si", "valencian": "ca", "norwegian bokmal": "no",
        "norwegian bokmål": "no", "norwegian nynorsk": "nn", "brazilian portuguese": "pt",
    ]

    /// The English name of a Whisper language code, if Whisper supports it.
    public static func name(for code: String) -> String? {
        names[code]
    }
}
