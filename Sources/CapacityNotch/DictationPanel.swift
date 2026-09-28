import AppKit
import Combine
import Murmur
import SwiftUI

@MainActor
final class DictationPanelController {
    private var panel: NSPanel
    private var observation: AnyCancellable?
    private var frame: NSRect = .zero

    init(controller: DictationController) {
        panel = Self.makePanel()
        panel.contentView = NSHostingView(rootView: FollowsLanguage { DictationCapsule(controller: controller).frame(width: 100, height: 100).padding(16) })
        observation = controller.$presentation.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self else { return }
            if state == .hidden { panel.orderOut(nil) }
            else { anchor(to: frame); panel.orderFrontRegardless() }
        }
    }

    /// Follows the surface. On macOS 27 a window kept out of capture never
    /// comes back, so sharing again moves the capsule into a new panel.
    func setSharingType(_ type: NSWindow.SharingType) {
        if type == .readOnly, panel.sharingType == .none {
            let old = panel, visible = old.isVisible
            panel = Self.makePanel()
            panel.contentView = old.contentView
            old.contentView = NSView()
            old.orderOut(nil)
            panel.setFrame(old.frame, display: false)
            if visible { panel.orderFrontRegardless() }
        }
        panel.sharingType = type
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    func anchor(to surface: NSRect) {
        frame = surface
        guard surface != .zero else { return }
        panel.setFrame(NSRect(x: surface.midX - 66, y: surface.minY - 12 - 100 - 16, width: 132, height: 132), display: true)
    }
}

struct DictationCapsule: View {
    @ObservedObject var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduced
    private let _audioLevel = State(initialValue: Float.zero)
    private let _details = State(initialValue: false)

    private var audioLevel: Float { _audioLevel.wrappedValue }
    private var murmurState: MurmurState {
        switch controller.presentation {
        case .hidden: .idle
        case .recording: .listening
        case .recognizing: .thinking
        case .inserted, .copied: .success
        case .error: .error
        }
    }

    private var tones: (MurmurRGBA, MurmurRGBA) {
        switch controller.presentation {
        case .inserted, .copied:
            (MurmurRGBA(r: 52.0 / 255, g: 199.0 / 255, b: 89.0 / 255), MurmurRGBA(r: 134.0 / 255, g: 239.0 / 255, b: 128.0 / 255))
        case .error:
            (MurmurRGBA(r: 229.0 / 255, g: 62.0 / 255, b: 62.0 / 255), MurmurRGBA(r: 255.0 / 255, g: 122.0 / 255, b: 92.0 / 255))
        default:
            (MurmurRGBA(r: 34.0 / 255, g: 183.0 / 255, b: 202.0 / 255), MurmurRGBA(r: 86.0 / 255, g: 223.0 / 255, b: 154.0 / 255))
        }
    }


    var body: some View {
        Button {
            if controller.presentation == .error || controller.presentation == .copied {
                _details.wrappedValue.toggle()
            }
        } label: {
            ZStack {
                MurmurView(
                    MurmurConfiguration(
                        style: .limn,
                        ink: MurmurRGBA(r: 23.0 / 255, g: 23.0 / 255, b: 23.0 / 255),
                        // The orb's own state motion alone read as still
                        // listening, so the outcome is also its colour.
                        tone: tones.0,
                        tone2: tones.1
                    ),
                    state: murmurState,
                    signals: MurmurSignals(level: controller.presentation == .recording ? Double(audioLevel) : 0),
                    animated: !reduced
                )
                    .frame(width: 100, height: 100)
            }
            .frame(width: 100, height: 100)
            .shadow(color: .black.opacity(0.2), radius: 9, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onReceive(controller.audioLevel) { _audioLevel.wrappedValue = $0 }
        .popover(isPresented: _details.projectedValue, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(controller.presentation == .copied ? L("Text copied, not inserted") : L("Dictation stopped")).font(.headline)
                Text(L(controller.presentation == .copied ? (controller.deliveryMessage ?? "Insertion was unavailable.") : (controller.error ?? "Try again.")))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if controller.presentation == .error {
                        Button(L("Open Dictation Settings")) { _details.wrappedValue = false; controller.cancel(); controller.openSettings() }
                    }
                    Button(L("Dismiss")) { _details.wrappedValue = false; controller.cancel() }
                }
            }.padding(18).frame(width: 310)
        }
    }

    private var accessibilityLabel: String {
        switch controller.presentation {
        case .recording: L("Recording. Release the shortcut to recognise. Escape cancels.")
        case .recognizing: L("Recognising speech. Escape cancels.")
        case .inserted: L("Text inserted and copied")
        case .copied: L("Text copied to clipboard. Tap for insertion details.")
        case .error: L("Dictation error. Show details.")
        case .hidden: L("Dictation")
        }
    }
}
