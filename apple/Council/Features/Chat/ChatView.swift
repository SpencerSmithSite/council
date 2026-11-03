import SwiftUI

struct ChatView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Ask", systemImage: "bubble.left.and.text.bubble.right", description: Text("Ask a question about the corpus."))
                .navigationTitle("Ask")
                .settingsToolbar()
        }
    }
}

#Preview {
    ChatView()
}
