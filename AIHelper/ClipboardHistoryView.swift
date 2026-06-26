import SwiftUI
import AppKit

struct ClipboardHistoryView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @State private var searchText = ""
    @State private var copiedItemId: UUID?
    @FocusState private var isSearchFocused: Bool

    var filteredItems: [ClipboardItem] {
        if searchText.isEmpty {
            return store.items
        }
        return store.items.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            searchBar

            Divider()

            // Content
            if store.items.isEmpty {
                emptyState
            } else if filteredItems.isEmpty {
                noResultsState
            } else {
                itemList
            }

            Divider()

            // Footer
            footer
        }
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            isSearchFocused = true
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search clipboard history...", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .padding()
    }

    // MARK: - Item List

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredItems) { item in
                    itemRow(item)
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
    }

    private func itemRow(_ item: ClipboardItem) -> some View {
        Button(action: { copyItem(item) }) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.preview)
                        .lineLimit(3)
                        .font(.system(.body))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Text(relativeTime(item.date))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let app = item.sourceAppName {
                            Text(app)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                        }
                    }
                }

                if copiedItemId == item.id {
                    Text("Copied!")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                } else {
                    Button(action: {
                        store.delete(item)
                    }) {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(copiedItemId == item.id ? Color.green.opacity(0.1) : Color.clear)
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No clipboard history")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Copy some text and it will appear here")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No matches")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Try a different search term")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            if !store.items.isEmpty {
                Button("Clear All") {
                    store.clearAll()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func copyItem(_ item: ClipboardItem) {
        store.copyToClipboard(item)

        withAnimation {
            copiedItemId = item.id
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            ClipboardHistoryWindowController.shared.hideWindow()
            copiedItemId = nil
        }
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    ClipboardHistoryView()
}
