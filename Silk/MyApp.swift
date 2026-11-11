import SwiftUI

@main
struct MyApp: App {
    @State private var store = IDEStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Python File…") {
                    store.isPresentingOpenDocument = true
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Save Python File…") {
                    store.isPresentingSaveDocument = true
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Workspace Files…") {
                    store.isPresentingWorkspaceFiles = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            CommandMenu("Run") {
                Button("Run All") {
                    store.runAll()
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button("Run Line or Selection") {
                    store.runLineOrSelection()
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])

                Divider()

                Button("Restart Python Runtime") {
                    store.restartRuntime()
                }
            }
        }
    }
}
