import SwiftUI
import AppKit

struct CortisolMenu: View {
    var manager: SleepManager

    var body: some View {
        if manager.isAwake {
            Text("Awake")
        } else {
            Text("Sleep Enabled")
        }

        if let time = manager.formattedTime {
            Text("\(time) remaining")
        }

        Divider()

        if manager.isAwake {
            Button("Allow Sleep") {
                manager.disableAwake()
            }
        } else {
            Button("Keep Awake") {
                manager.enableAwake()
            }

            Menu("Keep Awake For...") {
                Button("1 Hour") { manager.enableAwake(duration: 3600) }
                Button("2 Hours") { manager.enableAwake(duration: 7200) }
                Button("4 Hours") { manager.enableAwake(duration: 14400) }
                Button("8 Hours") { manager.enableAwake(duration: 28800) }
            }
        }

        Menu("Turn Off Display After...") {
            ForEach(SleepManager.displaySleepOptions, id: \.self) { minutes in
                Button {
                    manager.setDisplaySleep(minutes: minutes)
                } label: {
                    let label = SleepManager.displaySleepLabel(for: minutes)
                    if manager.displaySleepMinutes == minutes {
                        Text("\(label) ✓")
                    } else {
                        Text(label)
                    }
                }
            }
        }

        Divider()

        Text(manager.powerSource)

        if manager.activeInterfaces.isEmpty {
            Text("No Network")
        } else {
            ForEach(manager.activeInterfaces, id: \.self) { iface in
                Text(iface)
            }
        }

        Divider()

        Button("Quit Cortisol") {
            manager.cleanup()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
