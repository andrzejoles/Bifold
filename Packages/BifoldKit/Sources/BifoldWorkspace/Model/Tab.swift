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
    /// Liczenie rozmiarów katalogów; `token` odróżnia zadanie od nowszego dla tej samej ścieżki
    /// (anulowane zadanie nie usuwa wpisu zadania uruchomionego po powrocie do katalogu).
    @ObservationIgnored private var sizeTasks: [VFSPath: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var visibleIndex: [VFSPath: Int] = [:]
    /// Rośnie przy każdej nawigacji — odświeżenie w tle nie nadpisze kursora ustawionego
    /// przez nowszą nawigację (np. fokus na właśnie utworzonym katalogu).
    @ObservationIgnored private var navigationGeneration = 0
    /// Liczba zastosowanych wyników jawnych nawigacji — odświeżenie, w trakcie którego któraś się
    /// zakończyła, jest nieaktualne (przywróciłoby kursor sprzed niej).
    @ObservationIgnored private var appliedNavigations = 0

    public init(path: VFSPath, viewMode: ViewMode = .details, sort: SortSpec = SortSpec(), showHidden: Bool = false, providers: ProviderRegistry) {
        self.path = path
        self.viewMode = viewMode
        self.sort = sort
        self.showHidden = showHidden
        self.providers = providers
        customTitle = Self.automaticTitle(for: path, provider: try? providers.provider(for: path))
    }

    deinit {
        MainActor.assumeIsolated {
            watchTask?.cancel()
            processTask?.cancel()
            sizeTasks.values.forEach { $0.task.cancel() }
        }
    }

    /// Zamknięta karta: przerywa obserwowanie katalogu i liczenie rozmiarów.
    func stopBackgroundWork() {
        watchTask?.cancel()
        watchTask = nil
        cancelSizeTasks()
    }

    private func cancelSizeTasks() {
        sizeTasks.values.forEach { $0.task.cancel() }
        sizeTasks = [:]
    }

    /// Tytuł karty: wyniki wyszukiwania, archiwum, serwer, telefon, terminal. Przy przejściu do innego
    /// dostawcy (np. z archiwum do katalogu domowego) wyliczany na nowo z dostawcy ścieżki.
    public var customTitle: String?
    /// Karta-terminal (SSH): zamiast listy plików panel pokazuje terminal z tym procesem.
    public var terminal: TerminalSpec?
    public var title: String { customTitle ?? (path.isRoot ? "/" : path.name) }
    /// Karta pokazuje wyniki wyszukiwania (elementy z różnych katalogów).
    public var isSearchResults: Bool { SearchResultsFS.isSearchResults(path) }
    public var isInArchive: Bool { ArchiveFS.isArchivePath(path) }

    // MARK: Nawigacja

    /// Karta na niedostępnym jeszcze miejscu (np. telefon bez „Zezwól”): pusta lista z komunikatem —
    /// odświeżenie (Ctrl+R) ponawia próbę w tym miejscu, a nie w poprzednim katalogu.
    public func showUnavailable(_ target: VFSPath, error: String) async {
        navigationGeneration += 1
        isLoading = false
        setPath(target)
        items = []
        selection = []
        loadError = error
        volume = nil
        await processNow()
    }

    /// Wczytuje katalog. Przy błędzie karta zostaje w poprzednim katalogu, a błąd jest rzucany
    /// (bez `loadError` — karta nadal pokazuje poprawny, poprzedni katalog).
    public func navigate(to target: VFSPath, focus: String? = nil, recordHistory: Bool = true) async throws {
        try await navigate(to: target, focus: focus, recordHistory: recordHistory, historyIndex: nil)
    }

    /// - Parameter newIndex: wstecz/dalej — indeks historii ustawiany razem ze zmianą katalogu (tylko
    ///   przy udanym wczytaniu, które nie przegrało z nowszą nawigacją).
    private func navigate(to target: VFSPath, focus: String?, recordHistory: Bool, historyIndex newIndex: Int?) async throws {
        // Karta-terminal zostaje terminalem — katalogi otwiera `Workspace.open` w nowej karcie.
        guard terminal == nil else { throw CommandError.notAvailable(L10n.tr("Karta z terminalem SSH nie pokazuje plików — otwórz je w nowej karcie")) }
        navigationGeneration += 1
        try await load(target, focus: focus, recordHistory: recordHistory, historyIndex: newIndex, generation: navigationGeneration, isReload: false)
    }

    /// Zmiana katalogu karty. Przejście do innego dostawcy wylicza tytuł na nowo — inaczej karta
    /// w katalogu domowym zostawała z tytułem „📦 x.zip” albo „🔍 …”.
    private func setPath(_ target: VFSPath) {
        let previous = path
        path = target
        guard target.provider != previous.provider, terminal == nil else { return }
        customTitle = Self.automaticTitle(for: target, provider: try? providers.provider(for: target))
    }

    /// Tytuł wynikający z dostawcy ścieżki (telefony nadaje `device.open` — nazwa modelu z urządzenia).
    static func automaticTitle(for path: VFSPath, provider: (any FileSystemProvider)?) -> String? {
        if let alias = RemoteFS.alias(of: path) { return "🌐 " + alias }
        if let results = provider as? SearchResultsFS { return "🔍 " + results.title }
        if let archive = provider as? ArchiveFS { return "📦 " + archive.displayName }
        return nil
    }

    /// Wczytanie katalogu przez nawigację albo odświeżenie. Wynik jest pomijany, gdy w trakcie zaczęła się
    /// nowsza nawigacja — inaczej wolny katalog (serwer, odświeżenie przy obciążeniu) nadpisywał kartę
    /// starym listingiem. Odświeżenie nie podbija numeru nawigacji (nie unieważnia jawnej nawigacji),
    /// a jego wynik obowiązuje tylko, jeśli karta jest nadal w tym samym katalogu.
    /// - Returns: `false`, gdy wynik pominięto.
    @discardableResult
    private func load(_ target: VFSPath, focus: String?, recordHistory: Bool, historyIndex newIndex: Int? = nil, generation: Int, isReload: Bool) async throws -> Bool {
        let appliedAtStart = appliedNavigations
        func isCurrent() -> Bool {
            navigationGeneration == generation && (!isReload || (path == target && appliedNavigations == appliedAtStart))
        }
        let provider = try providers.provider(for: target)
        if !isReload { isLoading = true }
        defer { if !isReload, navigationGeneration == generation { isLoading = false } }
        let listed: [FileItem]
        do {
            listed = try await provider.list(target, options: ListOptions())
        } catch {
            guard isCurrent() else { return false }
            // Jawna nawigacja rzuca błąd, a karta zostaje w poprawnym katalogu; komunikat w pasku
            // ścieżki tylko przy nieudanym odświeżeniu bieżącego katalogu.
            if isReload { loadError = error.localizedDescription }
            throw error
        }
        guard isCurrent() else { return false }
        if !isReload { appliedNavigations += 1 }
        let changedDirectory = target != path
        setPath(target)
        loadError = nil
        items = listed
        if changedDirectory {
            selection = []
            directorySizes = [:]
            quickFilter = ""
            cancelSizeTasks()
        }
        if recordHistory && (historyIndex < 0 || history[historyIndex] != target) {
            history = Array(history.prefix(historyIndex + 1)) + [target]
            historyIndex = history.count - 1
        }
        if let newIndex { historyIndex = newIndex }
        let focusPath = focus.map { target.appending($0) }
        await processNow()
        guard isCurrent() else { return false }
        if let focusPath, visibleIndex[focusPath] != nil {
            cursor = focusPath
        } else if changedDirectory || cursor.map({ visibleIndex[$0] == nil }) ?? true {
            cursor = visibleItems.first(where: { !$0.isParentLink })?.path ?? visibleItems.first?.path
        }
        let info = try? await provider.volumeInfo(for: target)
        guard isCurrent() else { return false }
        volume = info
        startWatching(provider)
        return true
    }

    /// Ponowne wczytanie bieżącego katalogu z zachowaniem kursora i zaznaczenia.
    public func reload() async {
        guard terminal == nil else { return }
        let keepCursor = cursor
        let keepIndex = cursorIndex
        let generation = navigationGeneration
        do {
            guard try await load(path, focus: nil, recordHistory: false, generation: generation, isReload: true) else { return }
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

    /// Wstecz/dalej: indeks historii zmienia się razem z katalogiem, dopiero po udanym wczytaniu — przy
    /// błędzie albo wygranej nowszej nawigacji (D47) indeks zgadza się z katalogiem karty.
    public func goBack() async throws {
        guard canGoBack else { return }
        let from = path
        let index = historyIndex - 1
        let target = history[index]
        let focus = from.isDescendant(of: target) ? from.components.dropFirst(target.components.count).first : nil
        try await navigate(to: target, focus: focus, recordHistory: false, historyIndex: index)
    }

    public func goForward() async throws {
        guard canGoForward else { return }
        let index = historyIndex + 1
        try await navigate(to: history[index], focus: nil, recordHistory: false, historyIndex: index)
    }

    /// Dostawcy używani przez kartę (bieżący katalog i historia) — `Workspace` wyrejestrowuje
    /// nieużywane archiwa i wyniki wyszukiwania.
    var usedProviders: Set<ProviderID> { Set([path.provider] + history.map(\.provider)) }

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

    public func selectAll() {
        selection = Set(visibleItems.filter { !$0.isParentLink }.map(\.path))
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

    /// Liczy rozmiar katalogu w tle (tylko dysk lokalny — `DirectorySizer` nie zna serwerów,
    /// archiwów ani telefonów).
    public func calculateSize(of item: FileItem) {
        guard item.isDirectory, item.path.isLocal, sizeTasks[item.path] == nil, directorySizes[item.path] == nil else { return }
        let path = item.path
        let token = UUID()
        let task = Task { [weak self] in
            let size = try? await DirectorySizer.size(of: path)
            guard let self else { return }
            // Anulowane zadanie (zmiana katalogu) nie usuwa wpisu nowszego zadania i nie zapisuje wyniku.
            guard self.sizeTasks[path]?.token == token else { return }
            self.sizeTasks[path] = nil
            if let size, !Task.isCancelled { self.setDirectorySize(size, for: path) }
        }
        sizeTasks[path] = (token, task)
    }

    /// Liczba trwających obliczeń rozmiaru (testy).
    var pendingSizeCount: Int { sizeTasks.count }

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

/// Proces terminala w karcie panelu (`ssh` do zapisanego połączenia). Bez sekretów: hasło podaje
/// połączenie główne SSH, `ssh` w terminalu korzysta z niego przez ControlPath.
public struct TerminalSpec: Sendable, Equatable {
    public var alias: String
    public var executable: String
    public var arguments: [String]
    /// Typ terminala (`TERM`), który ssh przekazuje na serwer.
    public var term: String

    public init(alias: String, executable: String, arguments: [String], term: String = RemoteConnection.defaultTerminalType) {
        self.alias = alias
        self.executable = executable
        self.arguments = arguments
        self.term = term
    }
}
