//
//  NESEmulatorApp.swift
//  NESEmulator
//
//  Created by kevin on 2025-10-03.
//

import SwiftUI

// Notification names for menu → view communication
extension Notification.Name {
    static let emulatorLoadROM = Notification.Name("emulatorLoadROM")
    static let emulatorReset = Notification.Name("emulatorReset")
}

@main
struct NESEmulatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: .emulatorLoadROM)) { _ in
                    // Forward event to ContentView using global Notification
                }
                .onReceive(NotificationCenter.default.publisher(for: .emulatorReset)) { _ in
                    // Forward event if needed (handled inside ContentView)
                }
        }
        .commands {
            CommandMenu("Emulator") {
                Button("Load ROM...") {
                    NotificationCenter.default.post(name: .emulatorLoadROM, object: nil)
                }
                .keyboardShortcut("O", modifiers: .command)

                Button("Reset") {
                    NotificationCenter.default.post(name: .emulatorReset, object: nil)
                }
                .keyboardShortcut("R", modifiers: .command)
            }
        }
    }
}
