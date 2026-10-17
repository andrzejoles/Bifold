import BifoldCore
import Foundation
import Observation

/// Karta panelu: katalog, widok, sortowanie, filtr, kursor i zaznaczenie.
/// Interfejs i API agenta czytają stan wyłącznie stąd.
@MainActor @Observable
public final class Tab: Identifiable {
    public let id = UUID()
    public private(set) var path: VFSPath
    public var viewMode: ViewMode
    public var sort: SortSpec { didSet { if sort != oldValue { reprocess() } } }
    public var quickFilter: String = "" { didSet { if quickFilter != oldValue { reprocess() } } }
    public var showHidden: Bool { didSet { if showHidden != oldValue { reprocess() } } }

    /// Wszystkie elementy katalogu (bez filtrowania).
    public private(set) var items: [FileItem] = []
    /// Elementy do wyświetlenia: „..”, potem posortowane i przefiltrowane.
    public private(set) var visibleItems: [FileItem] = []
    /// Rośnie przy każdej zmianie `visibleItems` (sygnał przeładowania widoku).
    public private(set) var generation = 0

    public var cursor: VFSPath?
    public private(set) var selection: Set<VFSPath> = []
    public private(set) var directorySizes: [VFSPath: DirectorySize] = [:]
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    public private(set) var volume: VolumeInfo?

    public private(set) var history: [VFSPath] = []
    public private(set) var historyIndex = -1

    @ObservationIgnored let providers: ProviderRegistry
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var processGeneration = 0
    @ObservationIgnored private var sizeTasks: [VFSPath: Task<Void, Never>] = [:]
    @ObservationIgnored private var visibleIndex: [VFSPath: Int] = [:]
    /// Rośnie przy każdej nawigacji — odświeżenie w tle nie nadpisze kursora ustawionego
    /// przez nowszą nawigację (np. fokus na właśnie utworzonym katalogu).
    @ObservationIgnored private var navigationGeneration = 0

    public init(path: VFSPath, viewMode: ViewMode = .details, sort: SortSpec = SortSpec(), showHidden: Bool = false, providers: ProviderRegistry) {
        self.path = path
        self.viewMode = viewMode
        self.sort = sort
        self.showHidden = showHidden
        self.providers = providers
    }

    deinit {
        MainActor.assumeIsolated {
            watchTask?.cancel()
            processTask?.cancel()
        }
    }

    /// Tytuł karty wyników wyszukiwania.
    public var customTitle: String?
    public var title: String { customTitle ?? (path.isRoot ? "/" : path.name) }
    /// Karta pokazuje wyniki wyszukiwania (elementy z różnych katalogów).
    public var isSearchResults: Bool { SearchResultsFS.isSearchResults(path) }
    public var isInArchive: Bool { ArchiveFS.isArchivePath(path) }

    // MARK: Nawigacja

    /// Wczytuje katalog. Przy błędzie karta zostaje w poprzednim katalogu, a błąd jest rzucany.
    public func navigate(to target: VFSPath, focus: String? = nil, recordHistory: Bool = true) async throws {
        navigationGeneration += 1
        let provider = try providers.provider(for: target)
        isLoading = true
        defer { isLoading = false }
        let listed: [FileItem]
        do {
            listed = try await provider.list(target, options: ListOptions())
        } catch {
            loadError = error.localizedDescription
            throw error
        }
        let changedDirectory = target != path
        path = target
        loadError = nil
        items = listed
        if changedDirectory {
            selection = []
            directorySizes = [:]
            quickFilter = ""
            sizeTasks.values.forEach { $0.cancel() }
            sizeTasks = [:]
        }
        if recordHistory && (historyIndex < 0 || history[historyIndex] != target) {
            history = Array(history.prefix(historyIndex + 1)) + [target]
            historyIndex = history.count - 1
        }
        let focusPath = focus.map { target.appending($0) }
        await processNow()
        if let focusPath, visibleIndex[focusPath] != nil {
            cursor = focusPath
        } else if changedDirectory || cursor.map({ visibleIndex[$0] == nil }) ?? true {
            cursor = visibleItems.first(where: { !$0.isParentLink })?.path ?? visibleItems.first?.path
        }
        volume = try? await provider.volumeInfo(for: target)
        startWatching(provider)
    }

    /// Ponowne wczytanie bieżącego katalogu z zachowaniem kursora i zaznaczenia.
    public func reload() async {
        let keepCursor = cursor
        let keepIndex = cursorIndex
        let generation = navigationGeneration + 1
        do {
            try await navigate(to: path, recordHistory: false)
            guard navigationGeneration == generation else { return }
        } catch {
            // Katalog zniknął — przejdź w górę do pierwszego istniejącego.
            var candidate = path.parent
            while let c = candidate {
                if (try? await navigate(to: c, focus: nil)) != nil { return }
                candidate = c.parent
            }
            return
        }
        if let keepCursor, visibleIndex[keepCursor] != nil {
            cursor = keepCursor
        } else if let keepIndex, !visibleItems.isEmpty {
            cursor = visibleItems[min(keepIndex, visibleItems.count - 1)].path
        }
        let existing = Set(items.map(\.path))
        selection = selection.intersection(existing)
    }

    /// Plik archiwum, jeśli karta jest wewnątrz archiwum.
    public var hostLocation: VFSPath? { (try? providers.provider(for: path))?.hostLocation }

    public func goUp() async throws {
        if path.isRoot, let host = hostLocation, let parent = host.parent {
            customTitle = nil
            try await navigate(to: parent, focus: host.name)
            return
        }
        guard let parent = path.parent else { return }
        try await navigate(to: parent, focus: path.name)
    }

    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    public func goBack() async throws {
        guard canGoBack else { return }
        let from = path
        historyIndex -= 1
        try await navigate(to: history[historyIndex], focus: from.isDescendant(of: history[historyIndex]) ? from.components.dropFirst(history[historyIndex].components.count).first : nil, recordHistory: false)
    }

    public func goForward() async throws {
        guard canGoForward else { return }
        historyIndex += 1
        try await navigate(to: history[historyIndex], recordHistory: false)
    }

    private func startWatching(_ provider: any FileSystemProvider) {
        watchTask?.cancel()
        let watched = path
        let stream = provider.watch(watched)
        watchTask = Task { [weak self] in
            for await change in stream {
                // Zbieramy serię zdarzeń (np. kopiowanie wielu plików) w jedno odświeżenie.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.path == watched else { return }
                switch change {
                case .contentsChanged, .directoryRemoved: await self.reload()
                }
            }
        }
    }

    // MARK: Przetwarzanie listingu

    var processingOptions: ListingProcessor.Options {
        ListingProcessor.Options(
            sort: sort, showHidden: showHidden, filter: quickFilter,
            directorySizes: directorySizes.mapValues(\.bytes),
            parentOverride: path.isRoot ? hostLocation?.parent : nil)
    }

    /// Sortowanie i filtrowanie w tle; wynik podmienia `visibleItems` w całości.
    /// Kolejne zmiany (np. wpisywanie filtra) anulują wcześniejsze przeliczenia — wygrywa ostatnie.
    func reprocess() {
        processGeneration += 1
        let generationAtStart = processGeneration
        let items = items, dir = path, options = processingOptions
        processTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ListingProcessor.process(items, in: dir, options: options)
            }.value
            guard let self, generationAtStart == self.processGeneration else { return }
            self.apply(result)
        }
    }

    /// Przelicza od razu i czeka na wynik (po wczytaniu katalogu, w testach).
    public func processNow() async {
        reprocess()
        await processTask?.value
    }

    private func apply(_ result: [FileItem]) {
        visibleItems = result
        visibleIndex = Dictionary(result.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        generation += 1
        if let c = cursor, visibleIndex[c] == nil {
            cursor = result.first(where: { !$0.isParentLink })?.path ?? result.first?.path
        }
    }

    // MARK: Kursor

    public var cursorIndex: Int? { cursor.flatMap { visibleIndex[$0] } }

    public var cursorItem: FileItem? { cursorIndex.map { visibleItems[$0] } }

    public func index(of path: VFSPath) -> Int? { visibleIndex[path] }

    public func moveCursor(to index: Int) {
        guard !visibleItems.isEmpty else { return }
        cursor = visibleItems[max(0, min(index, visibleItems.count - 1))].path
    }

    /// Szybkie wyszukiwanie: kursor na pierwszy element zaczynający się od `prefix`
    /// (od bieżącego, z zawijaniem). Zwraca `false`, jeśli nic nie pasuje.
    @discardableResult
    public func quickSearch(_ prefix: String, startingAfterCursor: Bool = false) -> Bool {
        guard !prefix.isEmpty, !visibleItems.isEmpty else { return false }
        let start = (cursorIndex ?? 0) + (startingAfterCursor ? 1 : 0)
        let n = visibleItems.count
        for offset in 0..<n {
            let i = (start + offset) % n
            let item = visibleItems[i]
            if !item.isParentLink, item.name.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil {
                cursor = item.path
                return true
            }
        }
        return false
    }

    // MARK: Zaznaczenie

    /// Elementy, na których działa komenda: zaznaczone albo (gdy brak zaznaczenia) element pod kursorem.
    public var targets: [FileItem] {
        if !selection.isEmpty {
            return visibleItems.filter { selection.contains($0.path) } + items.filter { selection.contains($0.path) && visibleIndex[$0.path] == nil }
        }
        if let item = cursorItem, !item.isParentLink { return [item] }
        return []
    }

    public var selectedItems: [FileItem] { items.filter { selection.contains($0.path) } }

    public func setSelected(_ path: VFSPath, _ selected: Bool) {
        guard visibleIndex[path].map({ !visibleItems[$0].isParentLink }) ?? items.contains(where: { $0.path == path }) else { return }
        if selected { selection.insert(path) } else { selection.remove(path) }
    }

    public func toggleSelection(_ path: VFSPath) {
        setSelected(path, !selection.contains(path))
    }

    public func setSelection(_ paths: Set<VFSPath>) {
        let valid = Set(items.map(\.path))
        selection = paths.intersection(valid)
    }

    public func selectAll(filesOnly: Bool = false) {
        selection = Set(visibleItems.filter { !$0.isParentLink && (!filesOnly || !$0.isNavigable) }.map(\.path))
    }

    public func clearSelection() { selection = [] }

    /// Odwraca zaznaczenie plików (jak `*` na klawiaturze numerycznej w TC); `includeDirectories`
    /// obejmuje także katalogi.
    public func invertSelection(includeDirectories: Bool = false) {
        let candidates = visibleItems.filter { !$0.isParentLink && (includeDirectories || !$0.isNavigable) }
        selection = Set(candidates.filter { !selection.contains($0.path) }.map(\.path))
    }

    /// Zaznacza (lub odznacza) widoczne elementy pasujące do maski. Zwraca liczbę dopasowań.
    @discardableResult
    public func select(mask: String, selected: Bool = true, includeDirectories: Bool = false) -> Int {
        let m = NameMask(mask)
        var count = 0
        for item in visibleItems where !item.isParentLink && (includeDirectories || !item.isNavigable || mask.hasSuffix("/")) {
            if m.matches(item) {
                count += 1
                if selected { selection.insert(item.path) } else { selection.remove(item.path) }
            }
        }
        return count
    }

    // MARK: Rozmiary katalogów

    public func setDirectorySize(_ size: DirectorySize, for path: VFSPath) {
        directorySizes[path] = size
        if sort.field == .size { reprocess() }
    }

    public func calculateSize(of item: FileItem) {
        guard item.isDirectory, sizeTasks[item.path] == nil, directorySizes[item.path] == nil else { return }
        let path = item.path
        sizeTasks[path] = Task { [weak self] in
            let size = try? await DirectorySizer.size(of: path)
            guard let self else { return }
            self.sizeTasks[path] = nil
            if let size { self.setDirectorySize(size, for: path) }
        }
    }

    public func isCalculatingSize(_ path: VFSPath) -> Bool { sizeTasks[path] != nil }

    /// Suma rozmiarów zaznaczenia (katalogi tylko, jeśli policzono).
    public var selectionSummary: (count: Int, bytes: Int64) {
        let sel = selectedItems
        let bytes = sel.reduce(Int64(0)) { sum, item in
            sum + (item.isDirectory ? (directorySizes[item.path]?.bytes ?? 0) : max(0, item.size))
        }
        return (sel.count, bytes)
    }

    public var totalSummary: (files: Int, directories: Int, bytes: Int64) {
        let shown = visibleItems.filter { !$0.isParentLink }
        let files = shown.filter { !$0.isNavigable }
        return (files.count, shown.count - files.count, files.reduce(0) { $0 + max(0, $1.size) })
    }
}
