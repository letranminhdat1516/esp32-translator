import Foundation

/// The screens `-demo <screen>` opens directly (ios/Tools/snap.sh).
enum DemoScreen: String, CaseIterable, Hashable, Sendable {
    case welcome, permissions, pair, language, live, lock, phoneonly, boardlost, history, glossary, settings, sharing

    var onboardingStep: OnboardingStep? {
        switch self {
        case .welcome: .welcome
        case .permissions: .permissions
        case .pair: .pair
        case .language: .language
        default: nil
        }
    }

    /// The screen named after `-demo` in the launch arguments; nil when absent or unknown.
    static func parse(_ arguments: [String]) -> DemoScreen? {
        guard let i = arguments.firstIndex(where: { $0 == "-demo" || $0 == "--demo" }), i + 1 < arguments.count else {
            return nil
        }
        return DemoScreen(rawValue: arguments[i + 1].lowercased())
    }
}
