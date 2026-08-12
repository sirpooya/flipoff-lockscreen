import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: LockController
    @ObservedObject private var updater = UpdateController.shared
    #if DEBUG
    #endif

    var body: some View {
        Group {
            if controller.state == .unlocked {
                Button {
                    controller.lock()
                } label: {
                    Label("Lock Screen", systemImage: "lock.fill")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            } else {
                Button {
                    controller.requestUnlock()
                } label: {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                }

                Button {
                    controller.requestPasswordUnlock()
                } label: {
                    Label("Unlock with Password", systemImage: "keyboard")
                }

                Divider()

                Label {
                    Text("Locked for \(Constants.formatElapsedTime(controller.elapsedTime))")
                        .foregroundStyle(.primary.opacity(0.7))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                } icon: {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            SettingsLink {
                Text("Settings\u{2026}")
            }
            .keyboardShortcut(",")

            // Hidden while locked — the updater refuses to run then anyway, and a
            // relaunch prompt over a live shield would be an unlock the hotkey never
            // authorised.
            if controller.state == .unlocked {
                Button("Check for Updates\u{2026}") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            Button("Quit FlipOff") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        // .flipOffLock / .flipOffUnlock / .flipOffUnlockPassword are observed by
        // LockController, not here — a menu-bar popover only exists while it's open,
        // so handling them in this view meant Settings' "Lock Now" and the URL
        // scheme silently did nothing whenever the menu was closed.
    }

}
