import Foundation
import Synchronization

/// Kto wywołał operację.
public enum Invoker: Codable, Sendable, Hashable {
    case user
    case agent(sessionID: String, agentName: String)

    public var isAgent: Bool { if case .agent = self { true } else { false } }

    public var agentSessionID: String? {
        if case let .agent(id, _) = self { id } else { nil }
    }
}

/// Zmiana zapisana w dzienniku razem z danymi potrzebnymi do jej odwrócenia.
public enum JournalAction: Codable, Sendable, Hashable {
    /// Utworzono pusty plik lub katalog. Odwrotność: do Kosza.
    case created(path: VFSPath, isDirectory: Bool)
    /// Skopiowano (`to` nie istniało wcześniej). Odwrotność: `to` do Kosza.
    case copied(from: VFSPath, to: VFSPath)
    /// Przeniesiono lub zmieniono nazwę. Odwrotność: przeniesienie z powrotem.
    case moved(from: VFSPath, to: VFSPath)
    /// Przeniesiono do Kosza. Odwrotność: przywrócenie z Kosza.
    case trashed(original: VFSPath, trashPath: VFSPath)
    /// Usunięto pusty katalog źródłowy po przeniesieniu zawartości. Odwrotność: utworzenie.
    case removedEmptyDirectory(path: VFSPath)
    /// Zmieniono atrybuty. Odwrotność: przywrócenie poprzednich.
    case attributesChanged(path: VFSPath, before: AttributeChange, after: AttributeChange)
    /// Zmieniono tagi Findera. Odwrotność: przywrócenie poprzednich.
    case tagsChanged(path: VFSPath, before: [String], after: [String])
    /// Trwałe usunięcie — nieodwracalne, zapisywane dla porządku.
    case deletedPermanently(path: VFSPath)

    public var isUndoable: Bool {
        if case .deletedPermanently = self { false } else { true }
    }
}

public struct JournalEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var action: JournalAction
    /// Odcisk elementu wynikowego tuż po operacji (do wykrywania późniejszych zmian).
    public var fingerprint: Fingerprint?
    /// Wpis cofnięty osobno (częściowe cofnięcie partii). Zapisywany w dzienniku osobnym wierszem.
    public var undone = false

    private enum CodingKeys: String, CodingKey { case id, date, action, fingerprint }

    public init(id: UUID = UUID(), date: Date = Date(), action: JournalAction, fingerprint: Fingerprint? = nil) {
        self.id = id
        self.date = date
        self.action = action
        self.fingerprint = fingerprint
    }
}

/// Wpisy jednej komendy (np. jedno F6 na 30 plikach) — cofane razem.
public struct JournalBatch: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var date: Date
    public var invoker: Invoker
    public var entries: [JournalEntry]
    public var undone: Bool
    /// Zadanie, które dopisuje wpisy, już się zakończyło. Partii trwającego zadania nie wolno cofać
    /// (Cmd+Z w trakcie kopiowania). Stan tylko w pamięci: po wczytaniu z dysku każda partia jest zakończona.
    public var finished = true

    private enum CodingKeys: String, CodingKey { case id, title, date, invoker, entries, undone }

    public init(id: UUID, title: String, date: Date, invoker: Invoker, entries: [JournalEntry], undone: Bool, finished: Bool = true) {
        self.id = id
        self.title = title
        self.date = date
        self.invoker = invoker
        self.entries = entries
        self.undone = undone
        self.finished = finished
    }

    /// Wpisy, które jeszcze można cofnąć.
    public var pendingEntries: [JournalEntry] { entries.filter { !$0.undone } }

    public var isUndoable: Bool { !undone && finished && entries.contains { $0.action.isUndoable && !$0.undone } }
}

/// Dziennik operacji zmieniających pliki. Trzyma partie w pamięci i dopisuje każdą zmianę
/// do pliku JSONL od razu (odporność na awarię) przez stale otwarty uchwyt `O_APPEND`.
/// Przy starcie plik jest przycinany (atomowo) do ostatnich `maxBatchesInMemory` partii.
public final class OperationJournal: Sendable {
    private struct State {
        var batches: [JournalBatch] = []
        var index: [UUID: Int] = [:]
    }

    private enum Line: Codable {
        case batch(id: UUID, title: String, date: Date, invoker: Invoker)
        case entry(batch: UUID, entry: JournalEntry)
        case undone(batch: UUID)
        case entriesUndone(batch: UUID, entries: [UUID])
    }

    private let state = Mutex(State())
    private let fileURL: URL?
    private let writeQueue = DispatchQueue(label: "bifold.journal")
    /// Deskryptor pliku dziennika (tylko na `writeQueue`); -1 = jeszcze nie otwarty.
    private let descriptor = Mutex<Int32>(-1)
    public let maxBatchesInMemory: Int

    /// - Parameter fileURL: plik JSONL; `nil` = tylko w pamięci (testy).
    public init(fileURL: URL? = nil, maxBatchesInMemory: Int = 1000) {
        self.fileURL = fileURL
        self.maxBatchesInMemory = maxBatchesInMemory
        if let fileURL {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            load(from: fileURL)
        }
    }

    deinit {
        let fd = descriptor.withLock { $0 }
        if fd >= 0 { close(fd) }
    }

    public var batches: [JournalBatch] { state.withLock { $0.batches } }

    public func batch(_ id: UUID) -> JournalBatch? {
        state.withLock { s in s.index[id].map { s.batches[$0] } }
    }

    /// - Parameter finished: `false` dla partii zadania, które dopiero się zaczyna (zakończ `endBatch`).
    @discardableResult
    public func beginBatch(title: String, invoker: Invoker, id: UUID = UUID(), finished: Bool = true) -> UUID {
        let batch = JournalBatch(id: id, title: title, date: Date(), invoker: invoker, entries: [], undone: false, finished: finished)
        state.withLock { s in
            s.batches.append(batch)
            if s.batches.count > maxBatchesInMemory {
                s.batches.removeFirst(s.batches.count - maxBatchesInMemory)
            }
            s.index = Dictionary(uniqueKeysWithValues: s.batches.enumerated().map { ($1.id, $0) })
        }
        append([.batch(id: id, title: title, date: batch.date, invoker: invoker)])
        return id
    }

    /// Zadanie skończyło dopisywać wpisy — od teraz partię można cofnąć.
    public func endBatch(_ batchID: UUID) {
        state.withLock { s in
            guard let i = s.index[batchID] else { return }
            s.batches[i].finished = true
        }
    }

    public func record(_ action: JournalAction, fingerprint: Fingerprint? = nil, in batchID: UUID) {
        let entry = JournalEntry(action: action, fingerprint: fingerprint)
        state.withLock { s in
            guard let i = s.index[batchID] else { return }
            s.batches[i].entries.append(entry)
        }
        append([.entry(batch: batchID, entry: entry)])
    }

    public func markUndone(_ batchID: UUID) {
        state.withLock { s in
            guard let i = s.index[batchID] else { return }
            s.batches[i].undone = true
        }
        append([.undone(batch: batchID)])
    }

    /// Częściowe cofnięcie: tylko wskazane wpisy partii (reszta zostaje do cofnięcia).
    public func markUndone(entries entryIDs: Set<UUID>, in batchID: UUID) {
        guard !entryIDs.isEmpty else { return }
        state.withLock { s in
            guard let i = s.index[batchID] else { return }
            for j in s.batches[i].entries.indices where entryIDs.contains(s.batches[i].entries[j].id) {
                s.batches[i].entries[j].undone = true
            }
        }
        append([.entriesUndone(batch: batchID, entries: entryIDs.sorted { $0.uuidString < $1.uuidString })])
    }

    /// Ostatnia partia, którą da się cofnąć (opcjonalnie tylko danego wywołującego).
    /// Partie trwających zadań są pomijane.
    public func lastUndoable(where predicate: (JournalBatch) -> Bool = { _ in true }) -> JournalBatch? {
        state.withLock { $0.batches.last { $0.isUndoable && predicate($0) } }
    }

    /// Wszystkie niecofnięte (i zakończone) partie sesji agenta, od najstarszej.
    public func batches(forAgentSession sessionID: String) -> [JournalBatch] {
        state.withLock { $0.batches.filter { $0.invoker.agentSessionID == sessionID && $0.isUndoable } }
    }

    /// Czeka, aż wszystkie wpisy trafią na dysk.
    public func flush() {
        writeQueue.sync {}
    }

    // MARK: Plik

    private static func encode(_ lines: [Line]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for line in lines {
            guard let encoded = try? encoder.encode(line) else { continue }
            data.append(encoded)
            data.append(0x0A)
        }
        return data
    }

    /// Dopisuje wiersze przez stale otwarty uchwyt `O_APPEND`. Istniejącego pliku nigdy nie zastępuje:
    /// jeśli nie da się go otworzyć do zapisu, wiersze przepadają, ale dotychczasowy dziennik zostaje.
    private func append(_ lines: [Line]) {
        guard let fileURL else { return }
        writeQueue.async { [self] in
            let data = Self.encode(lines)
            guard !data.isEmpty else { return }
            descriptor.withLock { fd in
                if fd < 0 {
                    fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { return }
                }
                let ok = data.withUnsafeBytes { buf -> Bool in
                    var offset = 0
                    while offset < buf.count {
                        let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                        if n < 0 { if errno == EINTR { continue }; return false }
                        offset += n
                    }
                    return true
                }
                if !ok {
                    // Następny wiersz spróbuje otworzyć plik od nowa.
                    close(fd)
                    fd = -1
                }
            }
        }
    }

    private func load(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var s = State()
        for line in data.split(separator: 0x0A) {
            guard let parsed = try? decoder.decode(Line.self, from: Data(line)) else { continue }
            switch parsed {
            case let .batch(id, title, date, invoker):
                s.index[id] = s.batches.count
                s.batches.append(JournalBatch(id: id, title: title, date: date, invoker: invoker, entries: [], undone: false))
            case let .entry(batch, entry):
                if let i = s.index[batch] { s.batches[i].entries.append(entry) }
            case let .undone(batch):
                if let i = s.index[batch] { s.batches[i].undone = true }
            case let .entriesUndone(batch, ids):
                guard let i = s.index[batch] else { continue }
                let set = Set(ids)
                for j in s.batches[i].entries.indices where set.contains(s.batches[i].entries[j].id) {
                    s.batches[i].entries[j].undone = true
                }
            }
        }
        if s.batches.count > maxBatchesInMemory {
            s.batches.removeFirst(s.batches.count - maxBatchesInMemory)
            s.index = Dictionary(uniqueKeysWithValues: s.batches.enumerated().map { ($1.id, $0) })
            compact(url, batches: s.batches)
        }
        state.withLock { $0 = s }
    }

    /// Przepisuje dziennik do zachowanych partii: nowy plik obok i atomowa zmiana nazwy.
    private func compact(_ url: URL, batches: [JournalBatch]) {
        var lines: [Line] = []
        for b in batches {
            lines.append(.batch(id: b.id, title: b.title, date: b.date, invoker: b.invoker))
            lines += b.entries.map { .entry(batch: b.id, entry: $0) }
            let undoneEntries = b.entries.filter(\.undone).map(\.id)
            if !undoneEntries.isEmpty { lines.append(.entriesUndone(batch: b.id, entries: undoneEntries)) }
            if b.undone { lines.append(.undone(batch: b.id)) }
        }
        let data = Self.encode(lines)
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return fsync(fd) == 0
        }
        close(fd)
        if !ok || rename(temp.path, url.path) != 0 { unlink(temp.path) }
    }
}
