import CapacityNotchCore
import Foundation

/// A sentence in Settings, in the language chosen in General (`Localization`).
func L(_ english: String) -> String { Localization.text(english) }

/// A sentence with numbers or names in it; the English is the format.
func L(_ english: String, _ arguments: CVarArg...) -> String {
    String(format: Localization.text(english), locale: Localization.current.locale, arguments: arguments)
}
