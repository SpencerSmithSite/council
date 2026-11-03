import SwiftUI

struct ChatHistoryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Chat History", systemImage: "clock.arrow.circlepath", description: Text("Past conversations will appear here."))
                .navigationTitle("Chat History")
                .settingsToolbar()
        }
    }
}

#Preview {
    ChatHistoryView()
}
