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
    /// Kopia katalogu: liczba elementów poddrzewa tuż po operacji (bez `.DS_Store`). Inna liczba przy
    /// cofaniu = ktoś dopisał lub usunął pliki → konflikt zamiast zabrania cudzych plików do Kosza.
    /// `nil` w starszych dziennikach i dla innych wpisów.
    public var itemCount: Int?
    /// Wpis cofnięty osobno (częściowe cofnięcie partii). Zapisywany w dzienniku osobnym wierszem.
    public var undone = false

    private enum CodingKeys: String, CodingKey { case id, date, action, fingerprint, itemCount }

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
/// Przy starcie plik jest przycinany (atomowo) od najstarszych partii do `maxBatchesInMemory` partii,
/// `maxEntries` wpisów i `maxBytes` bajtów (najnowsza partia zostaje zawsze). W pamięci przy każdej nowej
/// partii obowiązuje limit partii i 2× limit wpisów, bez partii trwających zadań i najnowszej zakończonej.
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
        case itemCount(batch: UUID, entry: UUID, count: Int)
    }

    private let state = Mutex(State())
    private let fileURL: URL?
    private let writeQueue = DispatchQueue(label: "bifold.journal")
    /// Deskryptor pliku dziennika (tylko na `writeQueue`); -1 = jeszcze nie otwarty.
    private let descriptor = Mutex<Int32>(-1)
    public let maxBatchesInMemory: Int
    /// Limit łącznej liczby wpisów (operacja na 100 000 plików to 100 000 wierszy dekodowanych przy starcie).
    public let maxEntries: Int
    /// Limit rozmiaru pliku dziennika (sprawdzany przy starcie).
    public let maxBytes: Int

    /// - Parameter fileURL: plik JSONL; `nil` = tylko w pamięci (testy).
    public init(fileURL: URL? = nil, maxBatchesInMemory: Int = 1000, maxEntries: Int = 100_000, maxBytes: Int = 32 << 20) {
        self.fileURL = fileURL
        self.maxBatchesInMemory = maxBatchesInMemory
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
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
            // W pamięci (długa sesja) z zapasem 2× limit wpisów — dokładne przycięcie robi start (D55).
            // Nigdy nie znika partia trwającego zadania (dalsze `record`/`endBatch` trafiłyby w próżnię
            // i operacji nie dałoby się cofnąć) ani najnowsza zakończona przed nową (świeża duża operacja).
            let newestFinished = s.batches.indices.dropLast().last { s.batches[$0].finished }
            let protected = s.batches.indices.map { i in
                !s.batches[i].finished || i == s.batches.count - 1 || i == newestFinished
            }
            let drop = Self.batchesToDrop(entries: s.batches.map(\.entries.count), bytes: nil, protected: protected,
                                          maxBatches: maxBatchesInMemory, maxEntries: maxEntries > Int.max / 2 ? .max : maxEntries * 2,
                                          maxBytes: maxBytes)
            if !drop.isEmpty {
                s.batches = s.batches.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
                s.index = Dictionary(uniqueKeysWithValues: s.batches.enumerated().map { ($1.id, $0) })
            } else {
                s.index[id] = s.batches.count - 1
            }
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

    /// - Returns: identyfikator wpisu (np. do `setItemCount`).
    @discardableResult
    public func record(_ action: JournalAction, fingerprint: Fingerprint? = nil, in batchID: UUID) -> UUID {
        let entry = JournalEntry(action: action, fingerprint: fingerprint)
        state.withLock { s in
            guard let i = s.index[batchID] else { return }
            s.batches[i].entries.append(entry)
        }
        append([.entry(batch: batchID, entry: entry)])
        return entry.id
    }

    /// Uzupełnia wpis kopii katalogu o liczbę elementów poddrzewa (znaną dopiero po skopiowaniu;
    /// sam wpis jest zapisywany wcześniej, żeby przetrwał awarię w trakcie kopiowania).
    public func setItemCount(_ count: Int, forEntry entryID: UUID, in batchID: UUID) {
        state.withLock { s in
            guard let i = s.index[batchID], let j = s.batches[i].entries.lastIndex(where: { $0.id == entryID }) else { return }
            s.batches[i].entries[j].itemCount = count
        }
        append([.itemCount(batch: batchID, entry: entryID, count: count)])
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
        guard fileURL != nil else { return }
        writeQueue.async { [self] in writeToFile(Self.encode(lines)) }
    }

    private func append(rawData data: Data) {
        guard fileURL != nil else { return }
        writeQueue.async { [self] in writeToFile(data) }
    }

    /// Tylko na `writeQueue`.
    private func writeToFile(_ data: Data) {
        guard let fileURL, !data.isEmpty else { return }
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

    private func load(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var s = State()
        // Rozmiar wierszy każdej partii (do limitu bajtów).
        var bytes: [Int] = []
        for line in data.split(separator: 0x0A) {
            guard let parsed = try? decoder.decode(Line.self, from: Data(line)) else { continue }
            let size = line.count + 1
            switch parsed {
            case let .batch(id, title, date, invoker):
                s.index[id] = s.batches.count
                s.batches.append(JournalBatch(id: id, title: title, date: date, invoker: invoker, entries: [], undone: false))
                bytes.append(size)
            case let .entry(batch, entry):
                guard let i = s.index[batch] else { continue }
                s.batches[i].entries.append(entry)
                bytes[i] += size
            case let .undone(batch):
                guard let i = s.index[batch] else { continue }
                s.batches[i].undone = true
                bytes[i] += size
            case let .entriesUndone(batch, ids):
                guard let i = s.index[batch] else { continue }
                bytes[i] += size
                let set = Set(ids)
                for j in s.batches[i].entries.indices where set.contains(s.batches[i].entries[j].id) {
                    s.batches[i].entries[j].undone = true
                }
            case let .itemCount(batch, entryID, count):
                guard let i = s.index[batch], let j = s.batches[i].entries.lastIndex(where: { $0.id == entryID }) else { continue }
                s.batches[i].entries[j].itemCount = count
                bytes[i] += size
            }
        }
        // Po wczytaniu każda partia jest zakończona — chroniona jest tylko najnowsza.
        let drop = Self.batchesToDrop(entries: s.batches.map(\.entries.count), bytes: bytes,
                                      protected: s.batches.indices.map { $0 == s.batches.count - 1 },
                                      maxBatches: maxBatchesInMemory, maxEntries: maxEntries, maxBytes: maxBytes)
        var compacted = false
        if !drop.isEmpty {
            s.batches = s.batches.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            s.index = Dictionary(uniqueKeysWithValues: s.batches.enumerated().map { ($1.id, $0) })
            compacted = compact(url, batches: s.batches)
        }
        if !compacted, let last = data.last, last != 0x0A {
            // Ucięty ostatni wiersz (awaria w trakcie zapisu) bez znaku nowej linii skleiłby się z następnym
            // dopisanym wierszem — przepadłyby oba. Kończymy go, zanim cokolwiek zostanie dopisane
            // (po udanym przycięciu plik ma tylko pełne wiersze; uchwyt nie może się otworzyć przed zmianą
            // nazwy). Także gdy przycięcie się nie udało — wtedy plik zostaje stary, z uciętym wierszem.
            append(rawData: Data([0x0A]))
        }
        state.withLock { $0 = s }
    }

    /// Które partie odrzucić (od najstarszych, z pominięciem chronionych), żeby zmieścić się w limitach.
    /// `bytes` — rozmiar wierszy każdej partii w pliku (`nil` = bez limitu bajtów, w pamięci).
    private static func batchesToDrop(entries: [Int], bytes: [Int]?, protected: [Bool], maxBatches: Int, maxEntries: Int, maxBytes: Int) -> Set<Int> {
        var count = entries.count
        var totalEntries = entries.reduce(0, +)
        var totalBytes = bytes?.reduce(0, +) ?? 0
        var drop: Set<Int> = []
        for i in entries.indices where !protected[i] {
            guard count > maxBatches || totalEntries > maxEntries || (bytes != nil && totalBytes > maxBytes) else { break }
            totalEntries -= entries[i]
            totalBytes -= bytes?[i] ?? 0
            count -= 1
            drop.insert(i)
        }
        return drop
    }

    /// Przepisuje dziennik do zachowanych partii: nowy plik obok i atomowa zmiana nazwy.
    /// - Returns: `false`, gdy się nie udało (stary plik zostaje bez zmian).
    @discardableResult
    private func compact(_ url: URL, batches: [JournalBatch]) -> Bool {
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
        guard fd >= 0 else { return false }
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
        if !ok || rename(temp.path, url.path) != 0 {
            unlink(temp.path)
            return false
        }
        return true
    }
}
