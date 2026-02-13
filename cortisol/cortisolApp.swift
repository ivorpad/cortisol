import SwiftUI
import AppKit

@main
struct cortisolApp: App {
    @State private var manager = SleepManager()

    var body: some Scene {
        MenuBarExtra {
            CortisolMenu(manager: manager)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: manager.menuBarIcon)
                if let time = manager.compactTime {
                    Text(time)
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
