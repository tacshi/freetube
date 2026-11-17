import Foundation

/// The locale tag handed to YouTubeKit (`YouTubeModel.selectedLocale`), which becomes the `hl`
/// (language) and `gl` (region) of every innertube request.
///
/// **Why not YouTubeKit's default** (`Locale.preferredLanguages[0]`): YouTube answers HTTP 400
/// "Request contains an invalid argument" to `account/account_menu` when `gl` or `hl` isn't one
/// it serves, and the Library then reads that as signed out. Two ways the default got there:
/// - a region YouTube doesn't operate in — on a Mac set to English (China), the first preferred
///   language is `en-CN`, so `gl` was `CN`;
/// - a tag with a script, `zh-Hans-CN`, which YouTubeKit splits into `gl` = `HANS-CN`.
///
/// So the tag is rebuilt from parts: the first preferred language's code, kept only when YouTube
/// accepts it (else English), and the system region, kept only when YouTube accepts it (else
/// US). Both lists come from probing `account_menu` with every ISO code (2026-11); YouTube
/// rarely adds countries, and an unlisted one just falls back to US.
nonisolated enum YouTubeLocale {
    /// e.g. `en-NZ`, `zh-HK`, `en-US` (for a region YouTube doesn't serve).
    static func tag(
        preferredLanguages: [String] = Locale.preferredLanguages,
        region: Locale.Region? = Locale.current.region
    ) -> String {
        let preferred = preferredLanguages.first.map { Locale.Language(identifier: $0) }
        let languageCode = preferred?.languageCode?.identifier.lowercased() ?? ""
        let language = supportedLanguages.contains(languageCode) ? languageCode : "en"

        // The system region first; the preferred language's own region (`en-NZ`) when unset.
        let regionCode = (region ?? preferred?.region)?.identifier.uppercased() ?? ""
        let country = supportedRegions.contains(regionCode) ? regionCode : "US"
        return "\(language)-\(country)"
    }

    // MARK: - YouTube's accepted codes

    /// `gl` values YouTube accepts.
    static let supportedRegions: Set<String> = [
        "AE", "AM", "AR", "AT", "AU", "AZ", "BA", "BD", "BE", "BG", "BH", "BO", "BR", "BY", "CA",
        "CH", "CL", "CO", "CR", "CY", "CZ", "DE", "DK", "DO", "DZ", "EC", "EE", "EG", "ES", "FI",
        "FR", "GB", "GE", "GH", "GR", "GT", "HK", "HN", "HR", "HU", "ID", "IE", "IL", "IN", "IQ",
        "IS", "IT", "JM", "JO", "JP", "KE", "KH", "KR", "KW", "KZ", "LA", "LB", "LI", "LK", "LT",
        "LU", "LV", "LY", "MA", "MD", "ME", "MK", "MT", "MX", "MY", "NG", "NI", "NL", "NO", "NP",
        "NZ", "OM", "PA", "PE", "PG", "PH", "PK", "PL", "PR", "PT", "PY", "QA", "RO", "RS", "RU",
        "SA", "SE", "SG", "SI", "SK", "SN", "SV", "TH", "TN", "TR", "TW", "TZ", "UA", "UG", "US",
        "UY", "VE", "VN", "YE", "ZA", "ZW"
    ]

    /// Two-letter `hl` values YouTube accepts.
    static let supportedLanguages: Set<String> = [
        "af", "am", "ar", "as", "az", "be", "bg", "bn", "bs", "ca", "cs", "da", "de", "el", "en",
        "es", "et", "eu", "fa", "fi", "fr", "gl", "gu", "he", "hi", "hr", "hu", "hy", "id", "is",
        "it", "ja", "ka", "kk", "km", "kn", "ko", "ky", "lo", "lt", "lv", "mk", "ml", "mn", "mr",
        "ms", "my", "nb", "ne", "nl", "no", "or", "pa", "pl", "pt", "ro", "ru", "si", "sk", "sl",
        "sq", "sr", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur", "uz", "vi", "zh", "zu"
    ]
}
