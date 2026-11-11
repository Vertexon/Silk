import SwiftUI

struct ContentView: View {
    var body: some View {
        IDEWorkspaceView()
    }
}

#Preview {
    ContentView()
        .environment(IDEStore(bootsAutomatically: false))
}
