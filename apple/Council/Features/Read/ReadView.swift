import SwiftUI

struct ReadView: View {
    var body: some View {
        ContentUnavailableView("Read", systemImage: "book", description: Text("Your shelf of works will appear here."))
            .navigationTitle("Read")
    }
}

#Preview {
    NavigationStack { ReadView() }
}
