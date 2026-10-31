import Foundation

/// Who Orbit works for: your name, company and a line about what you do (Settings → General →
/// About you). Bots and Smart Ask get this, so their instructions never name a specific person.
/// Texts use {{name}} (first name), {{fullName}}, {{company}} and {{intro}}; `fill` swaps them in.
enum UserProfile {
    static let fullNameKey = "profile.fullName"
    static let companyKey = "profile.company"
    static let aboutKey = "profile.about"

    /// What Orbit calls you ("Sam"): the name from onboarding, else the first part of your Mac account name.
    static var firstName: String {
        let saved = (UserDefaults.standard.string(forKey: "look.name") ?? "").trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty { return saved }
        return fullName.split(separator: " ").first.map(String.init) ?? "you"
    }

    static var fullName: String {
        let saved = (UserDefaults.standard.string(forKey: fullNameKey) ?? "").trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty { return saved }
        let account = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return account.isEmpty ? "the user" : account
    }

    static var company: String { (UserDefaults.standard.string(forKey: companyKey) ?? "").trimmingCharacters(in: .whitespaces) }
    static var about: String { (UserDefaults.standard.string(forKey: aboutKey) ?? "").trimmingCharacters(in: .whitespaces) }

    /// "Sweden", from the Mac's region.
    static var country: String? {
        Locale.current.region.flatMap { Locale(identifier: "en").localizedString(forRegionCode: $0.identifier) }
    }

    /// One or two sentences for a bot: "Sam Lee works at Northwind, in Sweden. Sells design services."
    static func intro(fullName: String = fullName, company: String = company, about: String = about,
                      country: String? = country) -> String {
        var s = fullName
        if !company.isEmpty { s += " works at \(company)" }
        if let country, !country.isEmpty { s += company.isEmpty ? " is based in \(country)" : ", in \(country)" }
        s += "."
        if !about.isEmpty { s += " " + (about.hasSuffix(".") ? about : about + ".") }
        return s
    }

    /// Swaps {{name}}, {{fullName}}, {{company}} and {{intro}} for your details.
    static func fill(_ text: String) -> String {
        fill(text, name: firstName, fullName: fullName, company: company, intro: intro())
    }

    static func fill(_ text: String, name: String, fullName: String, company: String, intro: String) -> String {
        text.replacingOccurrences(of: "{{intro}}", with: intro)
            .replacingOccurrences(of: "{{fullName}}", with: fullName)
            .replacingOccurrences(of: "{{name}}", with: name)
            .replacingOccurrences(of: "{{company}}", with: company.isEmpty ? "their company" : company)
    }
}
