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
            toolbar
                .padding(.horizontal, DS.space16)
                .padding(.vertical, DS.space12)
                .background(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .fill(Color.primary.opacity(DS.rowStrokeOpacity))
                        .frame(height: DS.hairline),
                    alignment: .bottom
                )

            if entries.isEmpty && !isLoading {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries, id: \.rowID) { entry in
                            HistoryRow(entry: entry)
                                .padding(.horizontal, DS.space16)
                                .padding(.vertical, DS.space12)
                                .onAppear {
                                    maybeLoadMore(triggeredBy: entry)
                                }
                            Divider()
                                .opacity(0.4)
                                .padding(.leading, DS.space16)
                        }
                        if isLoading {
                            HStack {
                                Spacer()
                                ProgressView().controlSize(.small)
                                Spacer()
                            }
                            .padding(.vertical, DS.space12)
                        }
                    }
                }
            }

            statusBar
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { reset() }
        .onReceive(NotificationCenter.default.publisher(for: .historyDidChange)) { _ in
            reset()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: DS.space10) {
            HStack(spacing: DS.space6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12, weight: .medium))
                TextField("Search transcripts", text: Binding(
                    get: { search },
                    set: { newValue in
                        search = newValue
                        reset()
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                if !search.isEmpty {
                    Button {
                        search = ""
                        reset()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, DS.space10)
            .padding(.vertical, DS.space8)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                    .strokeBorder(Color.primary.opacity(DS.cardStrokeOpacity), lineWidth: DS.hairline)
            )
        }
    }

    private var statusBar: some View {
        HStack {
            Text(footerText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                HistoryStore.shared.deleteAll()
            } label: {
                Label("Clear all", systemImage: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(entries.isEmpty)
        }
        .padding(.horizontal, DS.space16)
        .padding(.vertical, DS.space10)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(DS.rowStrokeOpacity))
                .frame(height: DS.hairline),
            alignment: .top
        )
    }

    private var footerText: String {
        let count = entries.count
        let suffix = canLoadMore ? "+" : ""
        let unit = count == 1 ? "entry" : "entries"
        return "\(count)\(suffix) \(unit)"
    }

    private var emptyState: some View {
        VStack(spacing: DS.space12) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.10))
                    .frame(width: 56, height: 56)
                Image(systemName: search.isEmpty ? "mic.slash" : "magnifyingglass")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                Text(search.isEmpty ? "No transcriptions yet" : "No matches")
                    .font(.system(size: 14, weight: .semibold))
                Text(search.isEmpty
                     ? "Hold Fn or your hotkey to dictate; transcripts show up here."
                     : "Try a different search term.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
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
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.space8) {
                Text(entry.createdAt, style: .relative)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                metaSeparator
                Text(String(format: "%.1fs", entry.durationSeconds))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let app = entry.appBundleID, !app.isEmpty {
                    metaSeparator
                    Text(app)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    copy(displayText)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("Copy to clipboard")
                .opacity(isHovered ? 1 : 0.5)
            }
            Text(displayText)
                .font(.system(size: 13))
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var metaSeparator: some View {
        Text("·")
            .foregroundStyle(.secondary)
            .font(.system(size: 11))
    }

    private var displayText: String {
        entry.cleaned.isEmpty ? entry.raw : entry.cleaned
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
