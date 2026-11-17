import Foundation

/// Every outside link the app shows, in one place.
enum Links {
    static let website = URL(string: "https://mikko.app")!          // TODO: confirm the domain
    static let privacy = URL(string: "https://mikko.app/privacy")!
    static let source = URL(string: "https://github.com/Anemo-Studio/mikko-app")!
    static let issues = URL(string: "https://github.com/Anemo-Studio/mikko-app/issues")!
    static let anemo = URL(string: "https://anemo.agency")!

    struct Product: Identifiable {
        let name: String
        let line: String
        let site: URL
        let appStore: URL?
        var id: String { name }
    }

    /// The family. Only apps that are live on the App Store get a store link.
    static let family: [Product] = [
        Product(name: "nokko", line: "Projects, time and invoices in plain Markdown.",
                site: URL(string: "https://nokko.dev")!,
                appStore: URL(string: "https://apps.apple.com/app/nokko-plan-track-invoice/id6823214749")!),
        Product(name: "kikko", line: "Private meeting notes, made on your Mac.",
                site: URL(string: "https://kikkonotes.com")!, appStore: nil),
        Product(name: "honmay", line: "A teleprompter that keeps your best take.",
                site: URL(string: "https://honmay.app")!, appStore: nil),
    ]
}
