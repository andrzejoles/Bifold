import BifoldCore
import Foundation
import Observation

public enum PanelSide: String, Codable, Sendable, CaseIterable {
    case left, right

    public var other: PanelSide { self == .left ? .right : .left }
}

@MainActor @Observable
public final class Panel {
    public let side: PanelSide
    public private(set) var tabs: [Tab]
    public private(set) var activeTabIndex: Int = 0
    public var showsTree: Bool

    @ObservationIgnored let providers: ProviderRegistry
    /// Wywoływane po zamknięciu karty (`Workspace` wyrejestrowuje wtedy nieużywane archiwa i wyniki).
    @ObservationIgnored var onTabClosed: (@MainActor () -> Void)?

    init(side: PanelSide, tabs: [Tab], activeTabIndex: Int = 0, showsTree: Bool = false, providers: ProviderRegistry) {
        precondition(!tabs.isEmpty)
        self.side = side
        self.tabs = tabs
        self.activeTabIndex = min(max(0, activeTabIndex), tabs.count - 1)
        self.showsTree = showsTree
        self.providers = providers
    }

    public var activeTab: Tab { tabs[activeTabIndex] }

    @discardableResult
    public func newTab(at path: VFSPath? = nil, activate: Bool = true) -> Tab {
        let current = activeTab
        let tab = Tab(path: path ?? current.path, viewMode: current.viewMode, sort: current.sort, showHidden: current.showHidden, providers: providers)
        tabs.insert(tab, at: activeTabIndex + 1)
        if activate { activeTabIndex += 1 }
        return tab
    }

    /// Zamyka kartę; ostatniej karty panelu nie da się zamknąć.
    @discardableResult
    public func closeTab(at index: Int? = nil) -> Bool {
        let i = index ?? activeTabIndex
        guard tabs.count > 1, tabs.indices.contains(i) else { return false }
        tabs.remove(at: i).stopBackgroundWork()
        if activeTabIndex >= tabs.count || i < activeTabIndex { activeTabIndex = max(0, activeTabIndex - 1) }
        onTabClosed?()
        return true
    }

    public func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
    }

    public func selectTab(id: UUID) {
        if let i = tabs.firstIndex(where: { $0.id == id }) { activeTabIndex = i }
    }

    public func nextTab() { activeTabIndex = (activeTabIndex + 1) % tabs.count }
    public func previousTab() { activeTabIndex = (activeTabIndex - 1 + tabs.count) % tabs.count }

    /// Zamienia aktywne karty dwóch paneli (całe karty: katalog, historia, tytuł i maszyna jadą razem).
    func swapActiveTabs(with other: Panel) {
        let mine = activeTab
        tabs[activeTabIndex] = other.activeTab
        other.tabs[other.activeTabIndex] = mine
    }
}

// MARK: - Zapis sesji (karty między uruchomieniami)

public struct SessionSnapshot: Codable, Sendable, Equatable {
    public struct TabState: Codable, Sendable, Equatable {
        public var path: VFSPath
        public var viewMode: ViewMode
        public var sort: SortSpec
        public var cursorName: String?
    }

    public struct PanelState: Codable, Sendable, Equatable {
        public var tabs: [TabState]
        public var activeTab: Int
        public var showsTree: Bool
    }

    public var left: PanelState
    public var right: PanelState
    public var activeSide: PanelSide
}

extension Panel {
    /// Karty z plikami; same karty-terminale — jedna karta w katalogu `home` (ścieżka karty-terminala
    /// wskazuje serwer, z którym po ponownym uruchomieniu nie ma połączenia).
    func fileTabs(home: VFSPath) -> [Tab] {
        let files = tabs.filter { $0.terminal == nil }
        return files.isEmpty ? [Tab(path: home, providers: providers)] : files
    }

    func snapshot(home: VFSPath) -> SessionSnapshot.PanelState {
        // Karty-terminale nie wracają po ponownym uruchomieniu (sesja SSH się skończyła).
        let files = fileTabs(home: home)
        return SessionSnapshot.PanelState(
            tabs: files.map { SessionSnapshot.TabState(path: $0.path, viewMode: $0.viewMode, sort: $0.sort, cursorName: $0.cursorItem?.name) },
            activeTab: files.firstIndex { $0 === activeTab } ?? 0, showsTree: showsTree)
    }
}
