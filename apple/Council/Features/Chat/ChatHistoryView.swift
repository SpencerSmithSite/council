import SwiftUI

struct ChatHistoryView: View {
    var body: some View {
        ContentUnavailableView("Chat History", systemImage: "clock.arrow.circlepath", description: Text("Past conversations will appear here."))
            .navigationTitle("Chat History")
            .councilScreenBackground()
    }
}

#Preview {
    NavigationStack { ChatHistoryView() }
}
