import CouncilCore
import SwiftUI

/// Jump to a section: the reader's table of contents, Flutter's
/// `_ContentsSheet` (lib/src/screens/source_reader_screen.dart).
///
/// A flat list works for a confession of forty articles and fails for a Bible:
/// scrolling 1,189 rows to reach Habakkuk is not navigation. So the sheet
/// filters (`.searchable`), and a work with books ("Genesis 1", "Genesis 2",
/// …, decided once from the whole work by `ContentsIndex`) shows each book
/// with a grid of its chapter numbers, as Books does. The book holding the
/// reader's place opens and scrolls into view, so the sheet lands where they
/// are rather than at the top of the Bible.
struct ContentsSheet: View {
    let index: ContentsIndex
    /// The section at the top of the reader.
    let current: Int?
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.councilPalette) private var palette
    @State private var filter = ""
    /// Books the reader opened or closed by hand, by stem. The current book
    /// starts open; see `isExpanded`.
    @State private var toggled: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                content
                    .onAppear { scrollToCurrent(proxy) }
            }
            .navigationTitle("Contents")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $filter, prompt: "Jump to…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
            .councilScreenBackground(grouped: true)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private var matches: [Int] { index.matching(filter) }

    @ViewBuilder
    private var content: some View {
        let matches = matches
        if matches.isEmpty {
            ContentUnavailableView.search(text: filter)
        } else if index.groups {
            grouped(index.grouped(matches))
        } else {
            flat(matches)
        }
    }

    private func flat(_ matches: [Int]) -> some View {
        List(matches, id: \.self) { section in
            Button {
                select(section)
            } label: {
                HStack {
                    Text(index.title(at: section))
                        .foregroundStyle(palette.text)
                    Spacer()
                    if section == current {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(section == current ? .isSelected : [])
            .councilListRow()
            .id(section)
        }
    }

    /// Two levels: the book, then its chapters as a grid of numbers. A hundred
    /// and fifty Psalms fit in a few rows this way, where as list rows they
    /// are a scroll of their own.
    private func grouped(_ groups: [ContentsIndex.Group]) -> some View {
        List(groups, id: \.stem) { group in
            DisclosureGroup(isExpanded: expansion(group, onlyGroup: groups.count == 1)) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 8)], spacing: 8) {
                    ForEach(group.members, id: \.self) { section in
                        chapterButton(section, in: group)
                    }
                }
                .padding(.vertical, 6)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.stem.isEmpty ? "Untitled" : group.stem)
                        .foregroundStyle(palette.text)
                    Text(group.members.count == 1 ? "1 section" : "\(group.members.count) sections")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                }
            }
            .councilListRow()
            .id(group.stem)
        }
    }

    @ViewBuilder
    private func chapterButton(_ section: Int, in group: ContentsIndex.Group) -> some View {
        let label = index.label(for: section, stem: group.stem)
        let button = Button {
            select(section)
        } label: {
            Text(label)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .accessibilityLabel(index.title(at: section))
        .accessibilityAddTraits(section == current ? .isSelected : [])

        if section == current {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// Open when it holds the reader's place, and when the filter has narrowed
    /// to a single book, since naming a book is itself a request to see inside
    /// it (Flutter's `expanded`). A tap flips either way.
    private func expansion(_ group: ContentsIndex.Group, onlyGroup: Bool) -> Binding<Bool> {
        let natural = onlyGroup || current.map(group.members.contains) == true
        return Binding {
            natural != toggled.contains(group.stem)
        } set: { open in
            if open == natural {
                toggled.remove(group.stem)
            } else {
                toggled.insert(group.stem)
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current else { return }
        if index.groups {
            proxy.scrollTo(index.stem(at: current), anchor: .top)
        } else {
            proxy.scrollTo(current, anchor: .center)
        }
    }

    private func select(_ section: Int) {
        dismiss()
        onSelect(section)
    }
}

#Preview {
    ContentsSheet(index: ContentsIndex(titles: (1...50).map { "Genesis \($0)" } + (1...40).map { "Exodus \($0)" }),
                  current: 44, onSelect: { _ in })
}
