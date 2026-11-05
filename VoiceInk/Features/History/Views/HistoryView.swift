import SwiftData
import SwiftUI

struct HistoryView: View {
    private struct PaginationCursor {
        let timestamp: Date
        let id: UUID
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var navigation: MainWindowNavigation
    @State private var searchText = ""
    @State private var detailTranscription: Transcription?
    @FocusState private var isSearchFocused: Bool
    @State private var selectedTranscriptions: Set<Transcription> = []
    @State private var showDeleteConfirmation = false
    @State private var isShowingInfo = false
    @State private var activePanel: HistoryPanel?
    @State private var displayedTranscriptions: [Transcription] = []
    @State private var isLoading = false
    @State private var hasMoreContent = true
    @State private var paginationCursor: PaginationCursor?
    @State private var isViewCurrentlyVisible = false
    @State private var totalCount: Int?

    private let exportService = VoiceInkCSVExportService()
    private let pageSize = 20

    @Query(Self.createLatestTranscriptionIndicatorDescriptor()) private var latestTranscriptionIndicator:
        [Transcription]

    private static func createLatestTranscriptionIndicatorDescriptor() -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    private func cursorQueryDescriptor(after cursor: PaginationCursor? = nil) -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [
                SortDescriptor(\Transcription.timestamp, order: .reverse),
                SortDescriptor(\Transcription.id, order: .reverse),
            ]
        )

        if !searchText.isEmpty {
            let query = searchText
            if let cursor {
                let cursorTimestamp = cursor.timestamp
                let cursorID = cursor.id
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    (transcription.text.localizedStandardContains(query)
                        || (transcription.enhancedText?.localizedStandardContains(query) ?? false))
                        && (transcription.timestamp < cursorTimestamp
                            || (transcription.timestamp == cursorTimestamp && transcription.id < cursorID))
                }
            } else {
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.text.localizedStandardContains(query)
                        || (transcription.enhancedText?.localizedStandardContains(query) ?? false)
                }
            }
        } else if let cursor {
            let cursorTimestamp = cursor.timestamp
            let cursorID = cursor.id
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.timestamp < cursorTimestamp
                    || (transcription.timestamp == cursorTimestamp && transcription.id < cursorID)
            }
        }

        // Fetch one extra row so the UI can determine whether another page exists.
        descriptor.fetchLimit = pageSize + 1

        return descriptor
    }

    private var allSelected: Bool {
        !displayedTranscriptions.isEmpty && displayedTranscriptions.allSatisfy { selectedTranscriptions.contains($0) }
    }

    private func openDetail(_ transcription: Transcription) {
        activePanel = nil
        isShowingInfo = false
        isSearchFocused = false
        detailTranscription = transcription
        navigation.showHistoryTranscription(id: transcription.id)
    }

    private func closeDetail() {
        activePanel = nil
        isShowingInfo = false
        detailTranscription = nil
        isSearchFocused = true
        navigation.closeHistoryTranscription()
    }

    private func restoreHistoryDetail(id: UUID) {
        guard detailTranscription?.id != id else { return }
        let targetID = id
        let descriptor = FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == targetID })
        guard let transcription = try? modelContext.fetch(descriptor).first else {
            navigation.discardHistoryTranscription(id: id)
            return
        }
        detailTranscription = transcription
    }

    var body: some View {
        ZStack {
            // Keep the list mounted so returning from details preserves its scroll position.
            historyContent
                .opacity(detailTranscription == nil ? 1 : 0)
                .allowsHitTesting(detailTranscription == nil)
                .disabled(detailTranscription != nil)
                .accessibilityHidden(detailTranscription != nil)

            if let transcription = detailTranscription {
                TranscriptionDetailView(
                    transcription: transcription,
                    isInfoPresented: $isShowingInfo,
                    onBack: closeDetail,
                    onTranscriptionUpdated: { updated in
                        guard detailTranscription?.id == transcription.id else { return }
                        isShowingInfo = false
                        detailTranscription = updated
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: detailTranscription?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .sidePanel(
            isPresented: .init(
                get: { activePanel != nil },
                set: { if !$0 { activePanel = nil } }
            ),
            dismissOnExitCommand: false
        ) {
            panelContent
        }
        .onExitCommand {
            if isShowingInfo {
                isShowingInfo = false
            } else if activePanel != nil {
                activePanel = nil
            } else if detailTranscription != nil {
                closeDetail()
            }
        }
        .alert("Delete Selected Items?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedTranscriptions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    localized:
                        "This action cannot be undone. Are you sure you want to delete \(selectedTranscriptions.count) items?"
                ))
        }
        .onAppear {
            isViewCurrentlyVisible = true
            isSearchFocused = true
            if let id = navigation.activeHistoryTranscriptionID { restoreHistoryDetail(id: id) }
            Task { await loadInitialContent() }
        }
        .onDisappear {
            isViewCurrentlyVisible = false
        }
        .onChange(of: navigation.activeHistoryTranscriptionID) { _, id in
            if let id {
                restoreHistoryDetail(id: id)
            } else {
                detailTranscription = nil
            }
        }
        .onChange(of: searchText) { _, _ in
            Task {
                resetPagination()
                await loadInitialContent()
            }
        }
        .onChange(of: latestTranscriptionIndicator.first?.id) { oldId, newId in
            guard isViewCurrentlyVisible else { return }
            if newId != oldId {
                Task {
                    resetPagination()
                    await loadInitialContent()
                }
            }
        }
    }

    // Matches the top of the Dashboard and Settings headers, plus room for the count line.
    private static let pageHeaderHeight: CGFloat = 164

    private var historyContent: some View {
        QuickPanelScaffold(headerHeight: Self.pageHeaderHeight) {
            if displayedTranscriptions.isEmpty && !isLoading {
                HistoryEmptyState(
                    hasSearchQuery: !searchText.isEmpty,
                    emptyMessage: "Your transcription history will appear here"
                )
            } else {
                historyList
            }
        } header: {
            pageHeader
        } footer: {
            selectionBar
        }
    }

    private var pageHeader: some View {
        AppPageHeader(eyebrow: "Library", title: "History", subtitle: countLine) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Palette.faint)
                    TextField("Search transcripts", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.appSans(13))
                        .focused($isSearchFocused)
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 12)
                .frame(width: 240, height: 34)
                .appSurfaceCard(cornerRadius: 9)

                HistoryIconButton(systemName: "gearshape", help: "History settings") {
                    activePanel = .settings
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 64)
        .frame(height: Self.pageHeaderHeight, alignment: .top)
    }

    private var countLine: LocalizedStringKey? {
        guard let totalCount else { return nil }
        return totalCount == 1
            ? "1 recording, kept on this Mac."
            : "\(Formatters.formattedNumber(totalCount)) recordings, kept on this Mac."
    }

    private struct DaySection: Identifiable {
        let id: Date
        let title: String
        let items: [Transcription]
    }

    /// Consecutive transcriptions from the same calendar day, newest first: "Today", "Yesterday", then the date.
    private var daySections: [DaySection] {
        let calendar = Calendar.current
        var sections: [DaySection] = []
        var currentDay: Date?
        var currentItems: [Transcription] = []

        func close() {
            guard let day = currentDay, !currentItems.isEmpty else { return }
            sections.append(DaySection(id: day, title: Self.dayTitle(for: day, calendar: calendar), items: currentItems))
        }

        for transcription in displayedTranscriptions {
            let day = calendar.startOfDay(for: transcription.timestamp)
            if day != currentDay {
                close()
                currentDay = day
                currentItems = []
            }
            currentItems.append(transcription)
        }
        close()
        return sections
    }

    private static func dayTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? day.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : day.formatted(.dateTime.day().month(.wide).year())
    }

    // MARK: - Search Header

    private var searchHeader: some View {
        HistorySearchHeader(
            searchText: $searchText,
            searchFocus: $isSearchFocused,
            isSearching: isLoading
        ) {
            Spacer()
            HistoryIconButton(systemName: "gearshape", help: "History settings") {
                activePanel = .settings
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            if !selectedTranscriptions.isEmpty {
                Text(String(format: String(localized: "%lld selected"), Int64(selectedTranscriptions.count)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondary)

                Spacer(minLength: 8)

                HistoryCommandButton("Analyze", systemImage: "chart.bar.xaxis") {
                    activePanel = .analysis
                }

                HistoryCommandButton("Export", systemImage: "square.and.arrow.up") {
                    exportService.exportTranscriptionsToCSV(transcriptions: Array(selectedTranscriptions))
                }

                HistoryCommandButton("Delete", systemImage: "trash", isDestructive: true) {
                    showDeleteConfirmation = true
                }
            }

            if allSelected {
                HistoryCommandButton("Deselect All") {
                    selectedTranscriptions.removeAll()
                }
            } else {
                HistoryCommandButton("Select All") {
                    Task { await selectAllTranscriptions() }
                }
                .disabled(displayedTranscriptions.isEmpty)
            }

            if selectedTranscriptions.isEmpty {
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: HistoryLayout.actionBarHeight)
    }

    // MARK: - History List

    private var historyList: some View {
        HistoryList(topInset: Self.pageHeaderHeight + 20, horizontalInset: 40) {
            ForEach(daySections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    AppSectionLabel(verbatim: section.title)
                        .padding(.leading, 2)

                    VStack(spacing: 0) {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, transcription in
                            if index > 0 {
                                Rectangle()
                                    .fill(AppTheme.Palette.line)
                                    .frame(height: 1)
                            }
                            HistoryTranscriptionRow(
                                transcription: transcription,
                                isSelected: selectedTranscriptions.contains(transcription),
                                onSelect: { openDetail(transcription) },
                                onToggleCheck: { toggleSelection(transcription) },
                                showsCopyButton: true,
                                style: .grouped
                            )
                            .id(transcription.id)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
                    .appSurfaceCard()
                }
                .padding(.bottom, 10)
            }

            if hasMoreContent {
                HistoryCommandButton("Load More") {
                    Task { await loadMoreContent() }
                }
                .disabled(isLoading)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Side Panel

    @ViewBuilder
    private var panelContent: some View {
        if let activePanel {
            switch activePanel {
            case .analysis:
                HistoryAnalysisPanelView(
                    transcriptions: Array(selectedTranscriptions),
                    onClose: { self.activePanel = nil }
                )
                .id(selectedTranscriptions.count)
            case .settings:
                HistorySettingsPanel(onClose: { self.activePanel = nil })
            }
        }
    }

    // MARK: - Data Loading

    @MainActor
    private func loadInitialContent() async {
        isLoading = true
        defer { isLoading = false }

        do {
            paginationCursor = nil
            let items = try modelContext.fetch(cursorQueryDescriptor())
            totalCount = try? modelContext.fetchCount(FetchDescriptor<Transcription>())
            let page = Array(items.prefix(pageSize))
            displayedTranscriptions = page
            paginationCursor = page.last.map { PaginationCursor(timestamp: $0.timestamp, id: $0.id) }
            hasMoreContent = items.count > pageSize
        } catch {
            print("Error loading transcriptions: \(error)")
        }
    }

    @MainActor
    private func loadMoreContent() async {
        guard !isLoading, hasMoreContent, let paginationCursor else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let items = try modelContext.fetch(cursorQueryDescriptor(after: paginationCursor))
            let page = Array(items.prefix(pageSize))
            displayedTranscriptions.append(contentsOf: page)
            self.paginationCursor = page.last.map { PaginationCursor(timestamp: $0.timestamp, id: $0.id) }
            hasMoreContent = items.count > pageSize
        } catch {
            print("Error loading more transcriptions: \(error)")
        }
    }

    @MainActor
    private func resetPagination() {
        displayedTranscriptions = []
        paginationCursor = nil
        hasMoreContent = true
        isLoading = false
    }

    // MARK: - Selection & Deletion

    private func toggleSelection(_ transcription: Transcription) {
        if selectedTranscriptions.contains(transcription) {
            selectedTranscriptions.remove(transcription)
        } else {
            selectedTranscriptions.insert(transcription)
        }
    }

    private func performDeletion(for transcription: Transcription) {
        if let url = transcription.availableHistoryAudioURL {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("Error deleting audio file: \(error.localizedDescription)")
            }
        }

        if detailTranscription?.id == transcription.id {
            closeDetail()
        }

        selectedTranscriptions.remove(transcription)
        modelContext.delete(transcription)
    }

    private func deleteSelectedTranscriptions() {
        for transcription in selectedTranscriptions {
            performDeletion(for: transcription)
        }
        selectedTranscriptions.removeAll()

        Task {
            do {
                try modelContext.save()
                NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
                await loadInitialContent()
            } catch {
                print("Error saving deletion: \(error.localizedDescription)")
                await loadInitialContent()
            }
        }
    }

    @MainActor
    private func selectAllTranscriptions() async {
        do {
            var allDescriptor = FetchDescriptor<Transcription>()

            if !searchText.isEmpty {
                let query = searchText
                allDescriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.text.localizedStandardContains(query)
                        || (transcription.enhancedText?.localizedStandardContains(query) ?? false)
                }
            }

            allDescriptor.propertiesToFetch = [\.id]
            let allTranscriptions = try modelContext.fetch(allDescriptor)
            selectedTranscriptions = Set(displayedTranscriptions)
            selectedTranscriptions.formUnion(allTranscriptions)
        } catch {
            print("Error selecting all transcriptions: \(error)")
        }
    }
}

private enum HistoryPanel {
    case analysis
    case settings
}
