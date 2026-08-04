import Foundation

enum WelcomeMessageSystem {
    static let messages: [String] = [
        "Lychee is free. AI subscriptions unfortunately aren’t. If Lychee made your music qualia 3% nicer, consider supporting.",
        "If Lychee earned a permanent spot in your menu bar, consider supporting it.",
        "Feedback, feature ideas, money - feel free to send it all my way.",
        "This app is free because charging for lyrics didn’t sit right with my heart. Donations, however, sit excellent with my wallet.",
    ]

    static func pick(excluding current: String? = nil) -> String {
        let available = messages.filter { $0 != current }
        return available.randomElement() ?? messages.randomElement() ?? ""
    }
}
