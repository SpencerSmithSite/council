import SwiftUI

struct ReadView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Read", systemImage: "book", description: Text("Your shelf of works will appear here."))
                .navigationTitle("Read")
                .settingsToolbar()
        }
    }
}

#Preview {
    ReadView()
}
