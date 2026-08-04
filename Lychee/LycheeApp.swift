//
//  LycheeApp.swift
//  Lychee
//
//  App entry point — menu bar only, no dock icon
//

import SwiftUI

@main
struct LycheeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Keep Settings scene so SwiftUI registers the app-menu "Settings…" slot,
        // but replace its action with our own so both Cmd+, and the popover button
        // route through AppDelegate.showSettings() — which manages the NSWindow
        // directly without touching activationPolicy.
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppDelegate.shared?.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Lychee") {
                    AppDelegate.shared?.handleCommandQuit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
