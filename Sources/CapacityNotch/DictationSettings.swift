import AppKit
import CapacityNotchCore
import SwiftUI

private struct ModuleHoverBlockedKey: EnvironmentKey { static let defaultValue = false }
private struct ModuleEditingKey: EnvironmentKey { static let defaultValue = Binding.constant(false) }
extension EnvironmentValues {
    var moduleHoverBlocked: Bool {
        get { self[ModuleHoverBlockedKey.self] }
        set { self[ModuleHoverBlockedKey.self] = newValue }
    }
    var moduleEditing: Binding<Bool> {
        get { self[ModuleEditingKey.self] }
        set { self[ModuleEditingKey.self] = newValue }
    }
}

enum ModuleShortcutCapture {
    static let notification = Notification.Name("CapacityNotch.moduleShortcutCapture")
    @MainActor static func setActive(_ active: Bool) {
        NotificationCenter.default.post(name: notification, object: active)
    }
}

enum BuiltInModule: String, CaseIterable {
    case music = "Music", teleprompter = "Teleprompter", dictation = "Dictation"
    var symbol: String { switch self { case .music: "music.note"; case .teleprompter: "text.alignleft"; case .dictation: "mic" } }
    var summary: String { switch self {
    case .music: "What's playing, with its controls, under Capacity."
    case .teleprompter: "Your Script, scrolling beside the camera."
    case .dictation: "Speak, then keep typing."
    } }
}
enum DictationSettingsPage { case overview, setup, replacements, history }

/// The shared fourth-module shape: disclosure and enablement are separate
/// controls. Hover is deliberate and never collapses a card on group exit.
struct ModuleHeader: View {
    let module: BuiltInModule
    let expanded: Bool
    let expand: () -> Void
    @Binding var isOn: Bool
    @Environment(\.moduleHoverBlocked) private var hoverBlocked
    private let _hover = State<Task<Void, Never>?>(initialValue: nil)
    var body: some View {
        HStack(spacing: 12) {
            Button(action: expand) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.text).frame(width: 32, height: 32)
                        .overlay { Image(systemName: module.symbol).font(.system(size: 16)).foregroundStyle(SettingsPalette.window) }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.rawValue).font(SettingsType.bodyMedium)
                        Text(module.summary).font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onKeyPress(.return) { expand(); return .handled }
            .accessibilityLabel("\(module.rawValue) settings")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .onHover { inside in
                _hover.wrappedValue?.cancel()
                guard inside, !expanded, !hoverBlocked else { return }
                _hover.wrappedValue = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                    // Don't fold an editor out from under its insertion point.
                    guard !hoverBlocked, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
                    expand()
                }
            }
            .onDisappear { _hover.wrappedValue?.cancel() }
            .onChange(of: hoverBlocked) { _, blocked in if blocked { _hover.wrappedValue?.cancel() } }
            Toggle(module.rawValue, isOn: $isOn).toggleStyle(SettingsSwitchStyle(standsAlone: true))
        }
        .padding(.horizontal, 10).frame(height: 56)
    }
}

struct ModulesSection: View {
    @ObservedObject var model: SettingsModel
    private let _keyboardLock = State(initialValue: false)
    private let _editing = State(initialValue: false)
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        if model.dictationPage == .overview {
            VStack(alignment: .leading, spacing: 4) {
                Text("Modules").font(SettingsType.title)
                Text("Built-in features. Each one is off until you turn it on.").foregroundStyle(SettingsPalette.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsCard {
                    ModuleHeader(module: .music, expanded: model.expandedModule == .music, expand: { expand(.music) }, isOn: $model.musicEnabled)
                    if model.expandedModule == .music {
                        Text("Open, the surface has a page for it. It is read through a part of macOS that Apple does not publish, which a macOS update could close.")
                            .font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
                            .fixedSize(horizontal: false, vertical: true).padding(.leading, 54).padding(.trailing, 10).padding(.bottom, 10)
                        if model.musicEnabled && model.musicUnreadable {
                            Text(MusicModule.unreadableGuidance).font(SettingsType.caption).foregroundStyle(SettingsPalette.destructive).padding(10)
                        }
                    }
                }
                TeleprompterCard(teleprompter: model.teleprompter, expanded: model.expandedModule == .teleprompter, expand: { expand(.teleprompter) })
                DictationCard(controller: model.dictation, expanded: model.expandedModule == .dictation, expand: { expand(.dictation) }, navigate: { model.dictationPage = $0 })
            }
            .environment(\.moduleHoverBlocked, _keyboardLock.wrappedValue || _editing.wrappedValue)
            .environment(\.moduleEditing, _editing.projectedValue)
            .onKeyPress { _ in _keyboardLock.wrappedValue = true; return .ignored }
            .simultaneousGesture(TapGesture().onEnded { _keyboardLock.wrappedValue = false })
            Text("Audio is never saved. Esc cancels without changing your clipboard.").font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
        } else {
            DictationSubpage(controller: model.dictation, page: model.dictationPage) { model.dictationPage = .overview; model.expandedModule = .dictation }
        }
    }
    private func expand(_ module: BuiltInModule) {
        withAnimation(reduced ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.2)) { model.expandedModule = module }
    }
}

private struct DictationCard: View {
    @ObservedObject var controller: DictationController
    let expanded: Bool
    let expand: () -> Void
    let navigate: (DictationSettingsPage) -> Void
    var body: some View {
        SettingsCard {
            ModuleHeader(module: .dictation, expanded: expanded, expand: expand, isOn: Binding(get: { controller.isEnabled }, set: {
                controller.setEnabled($0)
                if $0 { expand(); if !controller.modelReady || !controller.microphoneAllowed { navigate(.setup) } }
            }))
            if expanded {
                if !controller.isEnabled {
                    Text("Hold a shortcut to turn speech into text, entirely on this Mac.").font(SettingsType.caption).foregroundStyle(SettingsPalette.muted).padding(.leading,54).padding(.trailing,10).padding(.bottom,10)
                } else {
                    SettingsDivider()
                    SettingsRow(indent: 44, hovers: false) {
                        Text("Hold to dictate"); Spacer(); DictationShortcutEditor(controller: controller)
                    }
                    if controller.shortcutUnavailable {
                        Text("This shortcut is in use. Choose another.").font(SettingsType.caption).foregroundStyle(SettingsPalette.destructive).padding(.leading, 54).padding(.bottom, 8)
                    }
                    SettingsDivider()
                    SettingsRow(indent: 44) {
                        Text(controller.modelReady ? "Model ready" : "Speech model"); Spacer()
                        if controller.modelReady { Button("Downloaded") { navigate(.setup) }.buttonStyle(.plain).font(SettingsType.caption).foregroundStyle(SettingsPalette.positive).help("Manage speech model") }
                        else { Button("Set up") { navigate(.setup) }.buttonStyle(SettingsButtonStyle()) }
                    }
                    SettingsDivider()
                    SettingsRow(indent: 44) {
                        Text("Automatic insertion"); Spacer()
                        if controller.insertionAllowed { Text("Allowed").font(SettingsType.caption).foregroundStyle(SettingsPalette.positive) }
                        else { Button("Enable") { navigate(.setup) }.buttonStyle(SettingsButtonStyle()) }
                    }
                    SettingsDivider()
                    SettingsRow(indent: 44) {
                        Text("Word replacements"); Spacer(); Button("Edit") { navigate(.replacements) }.buttonStyle(SettingsButtonStyle())
                    }
                    SettingsDivider()
                    SettingsToggleRow("Keep history", isOn: $controller.keepsHistory, indent: 44)
                    SettingsDivider()
                    SettingsRow(indent: 44) {
                        Text(controller.history.entries.isEmpty ? "No saved results" : "\(controller.history.entries.count) saved results").font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
                        Spacer()
                        Button("View history") { navigate(.history) }.buttonStyle(SettingsButtonStyle())
                    }
                    if !controller.microphoneAllowed {
                        SettingsRow(indent: 44) { Button("Allow microphone access") { navigate(.setup) }.buttonStyle(SettingsButtonStyle()); Spacer() }
                    }
                }
            }
        }
    }
}

private struct DictationSubpage: View {
    @ObservedObject var controller: DictationController
    let page: DictationSettingsPage
    let back: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("‹ Modules / Dictation", action: back).buttonStyle(.plain).font(SettingsType.caption).foregroundStyle(SettingsPalette.icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(SettingsType.title)
                Text(subtitle).foregroundStyle(SettingsPalette.muted)
            }
        }
        switch page {
        case .setup: DictationSetup(controller: controller)
        case .history: DictationHistoryView(controller: controller)
        case .replacements: DictationReplacementsView(controller: controller)
        case .overview: EmptyView()
        }
    }
    private var title: String { switch page { case .setup: "Set up Dictation"; case .history: "Dictation history"; case .replacements: "Word replacements"; case .overview: "Dictation" } }
    private var subtitle: String { switch page { case .setup: "Speak in Russian, with the IT terms you use every day."; case .history: "Your last 50 results, kept only on this Mac."; case .replacements: "Choose how recognised words are written."; case .overview: "" } }
}

private struct DictationSetup: View {
    @ObservedObject var controller: DictationController
    var body: some View {
        if !controller.isEnabled {
            Button("Turn on Dictation") { controller.setEnabled(true) }.buttonStyle(SettingsButtonStyle())
        }
        VStack(alignment: .leading, spacing: 16) {
            step(1, "Download the speech model", complete: controller.modelReady)
            Text("One download, then recognition works offline.\nGigaAM v3 · 170 MB download · 232 MB on disk").lineSpacing(3)
            if let progress = controller.downloadProgress {
                ProgressView(value: progress)
                HStack {
                    Text(progress >= 1 ? "Checking the model…" : "Downloading · \(Int(progress * 100))%").font(SettingsType.caption)
                    Spacer(); Button("Cancel") { controller.cancelDownload() }.buttonStyle(SettingsButtonStyle())
                }
            } else {
                HStack {
                    Button("Source & licences ↗") {
                        if let url = Bundle.main.url(forResource: "DictationLicenses", withExtension: "txt") ?? Bundle.module.url(forResource: "DictationLicenses", withExtension: "txt") { NSWorkspace.shared.open(url) }
                    }
                        .buttonStyle(.plain).font(SettingsType.caption)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([DictationModelFiles.directory])
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!controller.modelReady)
                    Button(controller.modelReady ? "Download again" : "Download • 170 MB") { controller.startDownload() }
                        .buttonStyle(SettingsButtonStyle()).disabled(!controller.isEnabled)
                }
            }
            if let error = controller.error { Text(error).font(SettingsType.caption).foregroundStyle(SettingsPalette.destructive) }
        }.padding(14).background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 10) {
            step(2, "Allow microphone access", complete: controller.microphoneAllowed)
            if controller.modelReady && !controller.microphoneAllowed {
                Text("Microphone access is needed only while recording.").font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
                Button("Allow microphone access") { controller.requestMicrophone() }.buttonStyle(SettingsButtonStyle()).disabled(!controller.isEnabled)
            } else if !controller.modelReady { Text("Requested after the model is ready.").font(SettingsType.caption).foregroundStyle(SettingsPalette.muted) }
        }.padding(.horizontal, 14)
        VStack(alignment: .leading, spacing: 10) {
            step(3, "Enable automatic insertion", complete: controller.insertionAllowed)
            Text("Optional. You can always paste from the clipboard.").font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
            if controller.modelReady && controller.microphoneAllowed && !controller.insertionAllowed {
                Button("Enable automatic insertion") { controller.requestInsertion() }.buttonStyle(SettingsButtonStyle()).disabled(!controller.isEnabled)
            }
        }.padding(.horizontal, 14)
        Text("Your audio stays on this Mac and is never saved.\nText history is off unless you choose to enable it.").font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
    }
    private func step(_ number: Int, _ text: String, complete: Bool) -> some View {
        HStack(spacing: 12) {
            Text(complete ? "✓" : "\(number)").font(SettingsType.caption).foregroundStyle(complete ? .white : SettingsPalette.window)
                .frame(width: 24, height: 24).background(complete ? SettingsPalette.positive : SettingsPalette.text, in: Circle())
            Text(text).font(.system(size: 14, weight: .semibold))
            Spacer()
        }
    }
}

private struct DictationHistoryView: View {
    @ObservedObject var controller: DictationController
    var body: some View {
        SettingsCard {
            SettingsRow(height: 56, hovers: false) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep history")
                    Text("Turning this off keeps your saved results.").font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
                }
                Spacer(); Toggle("Keep history", isOn: $controller.keepsHistory).toggleStyle(SettingsSwitchStyle(standsAlone: true))
            }
        }
        HStack {
            Text("\(controller.history.entries.count) results").font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
            Spacer()
            Button("Clear History") { controller.clearHistory() }.buttonStyle(.plain).font(SettingsType.caption).foregroundStyle(SettingsPalette.destructive).disabled(controller.history.entries.isEmpty)
        }
        if controller.history.entries.isEmpty {
            Text(controller.keepsHistory ? "Your next dictation will appear here." : "No saved results. Turn on Keep history to save future dictations.")
                .foregroundStyle(SettingsPalette.muted).padding(.vertical, 20)
        }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.history.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.date.formatted(date: Calendar.current.isDateInToday(entry.date) ? .omitted : .abbreviated, time: .shortened))
                            .font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
                        Spacer()
                        HStack(spacing: 6) {
                            DictationIconButton("doc.on.doc", label: "Copy") { controller.copy(entry.text) }
                            DictationIconButton("trash", label: "Delete") { controller.delete(entry.id) }
                        }
                    }
                    Text(entry.text).font(SettingsType.body).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 8).padding(.horizontal, 14)
                    .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.ring, lineWidth: 1))
            }
        }
    }
}

private struct DictationIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    init(_ symbol: String, label: String, action: @escaping () -> Void) { self.symbol = symbol; self.label = label; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 14, height: 14)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain).foregroundStyle(SettingsPalette.text)
            .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsPalette.ring, lineWidth: 1))
            .shadow(color: SettingsPalette.ring, radius: 1, y: 1)
            .help(label).accessibilityLabel(label)
    }
}

private struct DictationReplacementsView: View {
    @ObservedObject var controller: DictationController
    var body: some View {
        HStack {
            Text("\(controller.replacements.filter(\.enabled).count) active rules").font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
            Spacer(); Button("+ Add replacement") { controller.replacements.insert(.init(heard: "", replacement: ""), at: 0) }.buttonStyle(SettingsButtonStyle())
        }
        table
        Text("Matches whole words and phrases, ignoring letter case.\nChanges apply to your next dictation.").font(SettingsType.caption).foregroundStyle(SettingsPalette.muted)
    }
    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 24, height: 1)
                Text("Recognised").frame(maxWidth: .infinity, alignment: .leading)
                Text("Replace with").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 24, height: 1)
            }.font(SettingsType.caption).foregroundStyle(SettingsPalette.icon).padding(.horizontal, 16).padding(.vertical, 12).background(SettingsPalette.hover)
            ForEach($controller.replacements) { $rule in
                Divider()
                HStack(spacing: 12) {
                    Toggle("Enable \(rule.heard)", isOn: $rule.enabled).labelsHidden().toggleStyle(.checkbox).frame(width: 24)
                    field("Recognised phrase", text: $rule.heard)
                    field("Replacement", text: $rule.replacement)
                    Button { controller.replacements.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("Delete replacement").accessibilityLabel("Delete \(rule.heard) replacement")
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
        }.background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text).textFieldStyle(.plain).font(SettingsType.caption).padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(SettingsPalette.ring, lineWidth: 1)).accessibilityLabel(label)
    }
}

private struct DictationShortcutEditor: View {
    @ObservedObject var controller: DictationController
    private let _monitor = State<Any?>(initialValue: nil)
    private let _recording = State(initialValue: false)
    @Environment(\.moduleEditing) private var editing
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Array(controller.shortcut.keycaps.enumerated()), id: \.offset) { _, cap in
                    Text(cap).font(SettingsType.keycap).foregroundStyle(SettingsPalette.muted).padding(.horizontal, 4).frame(minWidth: 20).frame(height: 20).background(SettingsPalette.keycap, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            Button(_recording.wrappedValue ? "Press keys…" : "Edit", action: record).buttonStyle(SettingsButtonStyle())
        }.onDisappear { finish() }
    }
    private func record() {
        if _recording.wrappedValue { finish(); return }
        _recording.wrappedValue = true; editing.wrappedValue = true; ModuleShortcutCapture.setActive(true); controller.suspendShortcut(true)
        _monitor.wrappedValue = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { finish(); return nil }
            var mods: KeyShortcut.Modifiers = []
            if event.modifierFlags.contains(.control) { mods.insert(.control) }
            if event.modifierFlags.contains(.option) { mods.insert(.option) }
            if event.modifierFlags.contains(.command) { mods.insert(.command) }
            if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
            guard !mods.isDisjoint(with: [.control, .option, .command]) else { return nil }
            controller.setShortcut(.init(keyCode: UInt32(event.keyCode), modifiers: mods, keyLabel: event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"))
            finish(); return nil
        }
    }
    private func finish() {
        if let monitor = _monitor.wrappedValue { NSEvent.removeMonitor(monitor) }
        _monitor.wrappedValue = nil
        if _recording.wrappedValue { ModuleShortcutCapture.setActive(false); controller.suspendShortcut(false) }
        _recording.wrappedValue = false; editing.wrappedValue = false
    }
}
