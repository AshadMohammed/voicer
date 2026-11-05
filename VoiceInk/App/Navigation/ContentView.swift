import AppKit
import OSLog
import SwiftUI

enum ViewType: String, CaseIterable, Identifiable, Hashable {
    case dashboard = "Dashboard"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case meetings = "Meetings"
    case audio = "Audio"
    case dictionary = "Dictionary"
    case settings = "Settings"
    case license = "VoiceInk Pro"

    var id: String { rawValue }
}

final class MainWindowNavigation: ObservableObject {
    static let shared = MainWindowNavigation()

    enum Location: Equatable {
        case section(ViewType)
        case meeting(UUID)
        case historyTranscription(UUID)
    }

    private enum DetailKind {
        case meeting
        case historyTranscription
    }

    @Published private(set) var selectedView: ViewType = .dashboard
    @Published private(set) var activeMeetingID: UUID?
    @Published private(set) var activeHistoryTranscriptionID: UUID?
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    private init() {}

    func navigate(to destination: String) {
        guard let viewType = ViewType(rawValue: destination) else {
            return
        }

        navigate(to: viewType)
    }

    func navigate(to destination: ViewType) {
        visit(.section(destination))
    }

    func showMeeting(id: UUID) {
        visit(.meeting(id))
    }

    func closeMeeting() {
        closeDetail(.meeting)
    }

    func showHistoryTranscription(id: UUID) {
        visit(.historyTranscription(id))
    }

    func closeHistoryTranscription() {
        closeDetail(.historyTranscription)
    }

    /// Closes a detail screen the same way Back does, so it is not pushed onto the back stack and
    /// Cmd+[ cannot reopen the screen that was just dismissed.
    private func closeDetail(_ kind: DetailKind) {
        let section: ViewType = kind == .meeting ? .meetings : .history
        guard isCurrent(kind) else {
            navigate(to: section)
            return
        }
        if let destination = backStack.popLast() {
            forwardStack.append(currentLocation)
            apply(destination)
        } else {
            apply(.section(section))
        }
    }

    /// Drops routes to a deleted item from both stacks before leaving its detail screen.
    func discardMeeting(id: UUID) {
        discardRoutes { $0 == .meeting(id) }
        if activeMeetingID == id {
            if let destination = backStack.popLast() {
                apply(destination)
            } else {
                apply(.section(.meetings))
            }
        }
    }

    func discardHistoryTranscription(id: UUID) {
        discardRoutes { $0 == .historyTranscription(id) }
        if activeHistoryTranscriptionID == id {
            if let destination = backStack.popLast() {
                apply(destination)
            } else {
                apply(.section(.history))
            }
        }
    }

    private func discardRoutes(matching predicate: (Location) -> Bool) {
        backStack.removeAll(where: predicate)
        forwardStack.removeAll(where: predicate)
    }

    /// Removes back and forward entries for meetings that no longer exist.
    func pruneMeetingRoutes(keeping ids: Set<UUID>) {
        discardRoutes {
            if case .meeting(let id) = $0 { return !ids.contains(id) }
            return false
        }
    }

    private func isCurrent(_ kind: DetailKind) -> Bool {
        switch kind {
        case .meeting:
            return selectedView == .meetings && activeMeetingID != nil
        case .historyTranscription:
            return selectedView == .history && activeHistoryTranscriptionID != nil
        }
    }

    func goBack() {
        guard !isEditingText(), let destination = backStack.popLast() else { return }
        forwardStack.append(currentLocation)
        apply(destination)
    }

    func goForward() {
        guard !isEditingText(), let destination = forwardStack.popLast() else { return }
        backStack.append(currentLocation)
        apply(destination)
    }

    private var currentLocation: Location {
        if selectedView == .meetings, let activeMeetingID { return .meeting(activeMeetingID) }
        if selectedView == .history, let activeHistoryTranscriptionID {
            return .historyTranscription(activeHistoryTranscriptionID)
        }
        return .section(selectedView)
    }

    private func visit(_ destination: Location) {
        guard destination != currentLocation else { return }
        backStack.append(currentLocation)
        forwardStack.removeAll()
        apply(destination)
    }

    private func apply(_ location: Location) {
        switch location {
        case .section(let section):
            activeMeetingID = nil
            activeHistoryTranscriptionID = nil
            selectedView = section
        case .meeting(let id):
            activeHistoryTranscriptionID = nil
            selectedView = .meetings
            activeMeetingID = id
        case .historyTranscription(let id):
            activeMeetingID = nil
            selectedView = .history
            activeHistoryTranscriptionID = id
        }
    }

    private func isEditingText() -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return !textView.isFieldEditor
    }
}

struct ContentView: View {
    private let logger = Logger(subsystem: "com.ashadmohammed.voicer", category: "ContentView")
    @EnvironmentObject private var navigation: MainWindowNavigation

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(selectedView: navigation.selectedView) { navigation.navigate(to: $0) }

            detailContent
        }
        .font(.body)
        .foregroundStyle(AppTheme.Palette.ink)
        .tint(AppTheme.Palette.accent)
        .frame(width: AppWindowLayout.width)
        .frame(minHeight: AppWindowLayout.minimumHeight)
        .onAppear {
            logger.notice("ContentView appeared")
        }
        .onDisappear {
            logger.notice("ContentView disappeared")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDestination)) { notification in
            if let destination = notification.userInfo?["destination"] as? String {
                logger.notice("navigateToDestination received: \(destination, privacy: .public)")
                navigation.navigate(to: destination)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        detailView(for: navigation.selectedView)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(detailBackground)
    }

    private var detailBackground: some View {
        AppPaperBackground()
            .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private func detailView(for viewType: ViewType) -> some View {
        switch viewType {
        case .dashboard:
            DashboardView()
        case .transcribeAudio:
            AudioTranscribeView()
        case .history:
            HistoryView()
        case .meetings:
            MeetingsView()
        case .audio:
            AudioSetupView()
        case .dictionary:
            DictionarySettingsView()
        case .settings:
            SettingsView()
        case .license:
            LicenseManagementView()
        }
    }
}
