import CapacityNotchCore
import Foundation
import SwiftUI

/// A sentence in Settings, in the language chosen in General (`Localization`).
func L(_ english: String) -> String { Localization.text(english) }

/// A sentence with numbers or names in it; the English is the format.
func L(_ english: String, _ arguments: CVarArg...) -> String {
    String(format: Localization.text(english), locale: Localization.current.locale, arguments: arguments)
}

/// Draws its content again the moment the language chosen in Settings
/// changes, for surfaces that live on without being reopened: the notch and
/// the Dictation Capsule.
struct FollowsLanguage<Content: View>: View {
    @AppStorage("language") private var language = AppLanguage.system.rawValue
    @ViewBuilder let content: Content

    var body: some View { content.id(language) }
}
