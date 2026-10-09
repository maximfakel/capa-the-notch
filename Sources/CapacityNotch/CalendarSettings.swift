import CapacityNotchCore
import SwiftUI

/// Settings ▸ Modules ▸ Calendar: the switch, what it reads, and — when macOS
/// refused — that it refused, and where to undo it. Every calendar is read;
/// the author chose no picker (2026-10-07).
struct CalendarCard: View {
    let calendar: CalendarController
    @ObservedObject var reader: CalendarReader
    let expanded: Bool
    let expand: () -> Void

    init(calendar: CalendarController, expanded: Bool, expand: @escaping () -> Void) {
        self.calendar = calendar
        reader = calendar.reader
        self.expanded = expanded
        self.expand = expand
    }

    var body: some View {
        SettingsCard {
            ModuleHeader(
                module: .calendar, expanded: expanded, expand: expand,
                isOn: Binding(get: { reader.isEnabled }, set: { calendar.setEnabled($0) })
            )
            if expanded {
                note(L("Events from every calendar on this Mac. Ten minutes before one starts it shows under Capacity, with Join when it carries a call link; open, the surface has a page for the day. Nothing is read while this is off."), colour: SettingsPalette.muted)
            }
            // Said whether the card is open or not: a switch that is on and
            // shows nothing would otherwise look broken.
            if reader.isEnabled {
                switch reader.access {
                case .granted:
                    EmptyView()
                case .refused:
                    note(L("macOS does not let CapaTheNotch read your calendars. Allow it in System Settings → Privacy & Security → Calendars."), colour: SettingsPalette.destructive)
                    action(L("Open Privacy Settings")) { calendar.openPrivacySettings() }
                case .notAsked:
                    note(L("Calendar access has not been asked for yet."), colour: SettingsPalette.muted)
                    action(L("Allow Calendar Access")) { calendar.requestAccess() }
                }
            }
        }
    }

    private func note(_ text: String, colour: Color) -> some View {
        Text(text)
            .font(SettingsType.caption)
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 54)
            .padding(.trailing, 10)
            .padding(.bottom, 10)
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .buttonStyle(SettingsButtonStyle())
            .padding(.leading, 54)
            .padding(.bottom, 12)
    }
}
