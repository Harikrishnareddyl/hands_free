import SwiftUI
import AppKit

struct HistoryView: View {
    @State private var entries: [HistoryStore.Entry] = []
    @State private var search: String = ""
    @State private var canLoadMore: Bool = true
    @State private var isLoading: Bool = false

    private let pageSize = 100

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()

            if entries.isEmpty && !isLoading {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries, id: \.rowID) { entry in
                            HistoryRow(entry: entry)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .onAppear {
                                    maybeLoadMore(triggeredBy: entry)
                                }
                            Divider()
                        }
                        if isLoading {
                            HStack {
                                Spacer()
                                ProgressView().controlSize(.small)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear all") {
                    HistoryStore.shared.deleteAll()
                }
                .disabled(entries.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { reset() }
        .onReceive(NotificationCenter.default.publisher(for: .historyDidChange)) { _ in
            reset()
        }
    }

    private var footerText: String {
        let count = entries.count
        let suffix = canLoadMore ? "+" : ""
        let unit = count == 1 ? "entry" : "entries"
        return "\(count)\(suffix) \(unit)"
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search transcripts", text: Binding(
                get: { search },
                set: { newValue in
                    search = newValue
                    reset()
                }
            ))
            .textFieldStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(search.isEmpty ? "No transcriptions yet." : "No matches.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pagination

    private func reset() {
        entries = []
        canLoadMore = true
        loadMore()
    }

    private func maybeLoadMore(triggeredBy entry: HistoryStore.Entry) {
        // Trigger when the last few rows come into view.
        guard canLoadMore, !isLoading else { return }
        guard let lastID = entries.last?.id else { return }
        let thresholdIndex = max(0, entries.count - 10)
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }),
              idx >= thresholdIndex || entry.id == lastID else { return }
        loadMore()
    }

    private func loadMore() {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        let query = search
        let offset = entries.count
        let limit = pageSize
        Task {
            let page = await Task.detached(priority: .userInitiated) {
                HistoryStore.shared.fetchPage(search: query, offset: offset, limit: limit)
            }.value
            // Guard against races: if search/offset changed while fetching, discard.
            if query == search, offset == entries.count {
                entries.append(contentsOf: page)
                canLoadMore = page.count == limit
            }
            isLoading = false
        }
    }
}

private extension HistoryStore.Entry {
    var rowID: Int64 { id ?? -1 }
}

private struct HistoryRow: View {
    let entry: HistoryStore.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1fs", entry.durationSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let app = entry.appBundleID, !app.isEmpty {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(app)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    copy(displayText)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
            Text(displayText)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayText: String {
        entry.cleaned.isEmpty ? entry.raw : entry.cleaned
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
