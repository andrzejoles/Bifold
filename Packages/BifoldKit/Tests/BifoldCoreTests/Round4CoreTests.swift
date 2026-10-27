import Foundation
import Synchronization
import Testing
@testable import BifoldCore

/// Czwarta runda przeglądu (Core): każdy test odtwarza zgłoszony błąd.
@Suite struct Round4CoreTests {
    // MARK: 1. Spotlight

    /// Ukośnik wsteczny w tekście przerywał proces (NSException w parserze zapytania Spotlight).
    @MainActor @Test func spotlightPredicateSurvivesSpecialCharacters() throws {
        for text in ["a\\", "x\"y\\", "\\", "\\\"", "\"", "a\u{0}b", "*", "?", "\\*", "$time.today", "ąę\\", "a\u{7F}\u{85}"] + Self.noncharacterTexts {
            let predicate = try #require(SpotlightSearch.predicate(for: text), "\(text.debugDescription)")
            // `start()` tłumaczy predykat z powrotem na zapytanie Spotlight — tu też nie może się wyłożyć.
            let query = NSMetadataQuery()
            query.predicate = predicate
            query.searchScopes = [URL(filePath: NSTemporaryDirectory())]
            #expect(query.start(), "\(text.debugDescription)")
            query.stop()
        }
        #expect(SpotlightSearch.predicate(for: "\u{0}\n") == nil)
        #expect(SpotlightSearch.predicate(for: "\u{7F}\u{85}") == nil)
        // Niecharaktery Unicode (U+FFFE, U+FFFF przerywały parser; pomijane są wszystkie).
        #expect(SpotlightSearch.predicate(for: Self.scalars(0xFFFE)) == nil)
        #expect(SpotlightSearch.predicate(for: Self.scalars(0xFDD0, 0xFFFF, 0x10FFFF)) == nil)
    }

    /// Kompilator Swift nie przyjmuje niecharakterów w literałach (`\u{FFFF}`), więc budujemy je z liczb.
    static func scalars(_ values: UInt32...) -> String {
        String(String.UnicodeScalarView(values.compactMap(Unicode.Scalar.init)))
    }

    static let noncharacterTexts = [
        "a" + scalars(0xFFFF) + "b", scalars(0xFFFE) + "x", scalars(0xFDD0) + "y", scalars(0xFDEF) + "z",
        "a" + scalars(0x10FFFF, 0x1FFFE),
    ]

    // MARK: 2. Częściowe cofnięcie z brakującym elementem

    /// F8 → opróżnienie Kosza → Cmd+Z: brakujący element nie blokuje na zawsze cofania starszych partii.
    @Test func missingStepDoesNotKeepBatchUndoable() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "a")
        let journal = OperationJournal()
        let ops = FileOperations(journal: journal)
        try await ops.makeDirectory(tmp.path.appending("wczesniej"))
        let batch = journal.beginBatch(title: "F8", invoker: .user)
        let trashed = try #require(try LocalFS().trashSync(tmp.path.appending("a.txt")))
        journal.record(.trashed(original: tmp.path.appending("a.txt"), trashPath: trashed), in: batch)
        // „Opróżnienie Kosza”.
        try FileManager.default.removeItem(atPath: trashed.path)

        let plan = try #require(ops.undoPlanForLast())
        #expect(plan.batches == [batch])
        #expect(plan.conflicts == [.missing(trashed)])
        let result = await ops.execute(plan)
        #expect(result.performed == 0 && result.skipped == [.missing(trashed)])
        // Następne Cmd+Z proponuje wcześniejszą partię, a nie ten sam konflikt.
        #expect(ops.undoPlanForLast()?.batches != [batch])
        #expect(journal.lastUndoable()?.title == L10n.tr("Nowy katalog \("wczesniej")"))
    }

    /// Partia z krokiem brakującym i zajętym: zostaje tylko krok zajęty.
    @Test func missingStepIsMarkedButOccupiedStays() async throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "a")
        try tmp.file("b.txt", "b")
        let journal = OperationJournal()
        let batch = journal.beginBatch(title: "zmiana nazw", invoker: .user)
        try LocalFS().moveSync(tmp.path.appending("a.txt"), to: tmp.path.appending("a2.txt"))
        journal.record(.moved(from: tmp.path.appending("a.txt"), to: tmp.path.appending("a2.txt")), in: batch)
        try LocalFS().moveSync(tmp.path.appending("b.txt"), to: tmp.path.appending("b2.txt"))
        journal.record(.moved(from: tmp.path.appending("b.txt"), to: tmp.path.appending("b2.txt")), in: batch)
        try tmp.file("a.txt", "zajmuje")
        try FileManager.default.removeItem(at: tmp.url.appending(path: "b2.txt"))

        let ops = FileOperations(journal: journal)
        let result = await ops.execute(try #require(ops.undoPlanForLast()))
        #expect(result.performed == 0 && result.skipped.count == 2)
        let again = try #require(ops.undoPlanForLast())
        #expect(again.steps.map(\.action) == [.move(from: tmp.path.appending("a2.txt"), to: tmp.path.appending("a.txt"))])
    }

    // MARK: 3. MultiRename — przepełnienia

    @Test func multiRenameSubstringDoesNotOverflow() {
        #expect(MultiRename.substring("abc", spec: "1,9223372036854775807") == "abc")
        #expect(MultiRename.substring("abc", spec: "9223372036854775807,2") == "")
        #expect(MultiRename.substring("abc", spec: "--9223372036854775808-") == "")
        #expect(MultiRename.substring("abc", spec: "-9223372036854775807-") == "abc")
        #expect(MultiRename.substring("abc", spec: "-9223372036854775808,2") == "")
        #expect(MultiRename.substring("abc", spec: "-9223372036854775808,9223372036854775807") == "abc")
        #expect(MultiRename.substring("abc", spec: "2,-9223372036854775808") == "")
        // Dotychczasowe znaczenie bez zmian.
        #expect(MultiRename.substring("abcdef", spec: "2-4") == "bcd")
        #expect(MultiRename.substring("abcdef", spec: "-3-") == "def")
        #expect(MultiRename.substring("abcdef", spec: "-5,2") == "bc")
        #expect(MultiRename.substring("abcdef", spec: "2,3") == "bcd")
    }

    @Test func multiRenameCounterWidthIsLimited() throws {
        let item = FileItem(path: .local("/x/plik.txt"), name: "plik.txt", kind: .file)
        let huge = MultiRename.plan([item], rule: RenameRule(nameMask: "[N][C:300000000]"))
        #expect(huge[0].problem != nil)
        #expect(huge[0].newName.utf8.count < 1000)
        let wide = MultiRename.plan([item], rule: RenameRule(nameMask: "[N][C:20]"))
        #expect(wide[0].problem == nil && wide[0].newName == "plik00000000000000000001.txt")
        let digits = MultiRename.plan([item], rule: RenameRule(nameMask: "[N][C]", counterDigits: 1_000_000))
        #expect(digits[0].problem != nil && digits[0].newName.utf8.count < 1000)
        // Licznik poza zakresem Int (start + indeks × krok) — problem zamiast pułapki.
        let items = (0..<3).map { FileItem(path: .local("/x/p\($0).txt"), name: "p\($0).txt", kind: .file) }
        let overflow = MultiRename.plan(items, rule: RenameRule(nameMask: "[N][C]", counterStart: Int.max - 1, counterStep: Int.max))
        #expect(overflow[0].problem == nil)
        #expect(overflow[1].problem != nil && overflow[2].problem != nil)
    }

    // MARK: 4. Cofnięcie kopii katalogu z dopisanym plikiem

    @Test func undoCopiedDirectoryDetectsForeignFiles() async throws {
        let tmp = try TempDir()
        try tmp.file("src/d/a.txt", "a")
        try tmp.file("src/d/sub/b.txt", "b")
        let file = tmp.url.appending(path: "journal/ops.jsonl")
        let journal = OperationJournal(fileURL: file)
        let batch = journal.beginBatch(title: "F5", invoker: .user)
        let engine = TransferEngine(request: TransferRequest(kind: .copy, sources: [tmp.path.appending("src/d")], destinationDirectory: try tmp.dir("dst")),
                                    journal: journal, batchID: batch)
        try engine.run()
        let ops = FileOperations(journal: journal)
        #expect(try #require(ops.undoPlanForLast()).conflicts.isEmpty)
        // Finder dopisuje .DS_Store po otwarciu katalogu — to nie cudzy plik.
        try tmp.file("dst/d/sub/.DS_Store", "x")
        #expect(try #require(ops.undoPlanForLast()).conflicts.isEmpty)
        try tmp.file("dst/d/sub/pozniej.txt", "cudzy")
        let dest = tmp.path.appending("dst/d")
        #expect(try #require(ops.undoPlanForLast()).conflicts == [.modified(dest)])
        // Liczba elementów przetrwa ponowne wczytanie dziennika.
        journal.flush()
        let reloaded = FileOperations(journal: OperationJournal(fileURL: file))
        #expect(try #require(reloaded.undoPlanForLast()).conflicts == [.modified(dest)])
        let result = await ops.execute(try #require(ops.undoPlanForLast()))
        #expect(result.performed == 0)
        #expect(tmp.exists("dst/d/sub/pozniej.txt"))
    }

    /// Stary dziennik (wpis kopii bez liczby elementów) wczytuje się i cofa jak dotąd.
    @Test func oldJournalCopiedEntryStillLoads() throws {
        let tmp = try TempDir()
        try tmp.file("dst/d/a.txt", "a")
        let dest = tmp.path.appending("dst/d")
        let file = tmp.url.appending(path: "ops.jsonl")
        let writer = OperationJournal(fileURL: file)
        let batch = writer.beginBatch(title: "stara kopia", invoker: .user)
        writer.record(.copied(from: .local("/zrodlo/d"), to: dest), in: batch)
        writer.flush()
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("itemCount"))
        let plan = try #require(FileOperations(journal: OperationJournal(fileURL: file)).undoPlanForLast())
        #expect(plan.steps.map(\.action) == [.trash(dest)] && plan.conflicts.isEmpty)
    }

    // MARK: 5. Limit wpisów dziennika

    @Test func journalIsCompactedByEntryCount() throws {
        let tmp = try TempDir()
        let file = tmp.url.appending(path: "ops.jsonl")
        let journal = OperationJournal(fileURL: file, maxEntries: 100_000)
        for b in 0..<3 {
            let batch = journal.beginBatch(title: "p\(b)", invoker: .user)
            for i in 0..<1_000 { journal.record(.created(path: tmp.path.appending("p\(b)-\(i)"), isDirectory: false), in: batch) }
        }
        journal.flush()
        let reloaded = OperationJournal(fileURL: file, maxEntries: 2_000)
        #expect(reloaded.batches.map(\.title) == ["p1", "p2"])
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2 + 2_000)
        // Najnowsza partia zostaje nawet ponad limit.
        #expect(OperationJournal(fileURL: file, maxEntries: 10).batches.map(\.title) == ["p2"])
        #expect(try tmp.names() == ["ops.jsonl"])
    }

    @Test func journalIsCompactedByBytes() throws {
        let tmp = try TempDir()
        let file = tmp.url.appending(path: "ops.jsonl")
        let journal = OperationJournal(fileURL: file)
        for b in 0..<4 {
            let batch = journal.beginBatch(title: "p\(b)", invoker: .user)
            for i in 0..<100 { journal.record(.created(path: tmp.path.appending("p\(b)-\(i)"), isDirectory: false), in: batch) }
        }
        journal.flush()
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        let reloaded = OperationJournal(fileURL: file, maxBytes: size / 2)
        #expect(reloaded.batches.map(\.title) == ["p2", "p3"])
        let newSize = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(newSize <= size / 2)
    }

    /// W pamięci (długa sesja) też obowiązuje limit wpisów — z zapasem 2× limit, sprawdzany przy
    /// rozpoczęciu nowej partii (najnowsza zakończona partia zostaje).
    @Test func journalTrimsEntriesInMemory() {
        let journal = OperationJournal(maxEntries: 50)
        for b in 0..<4 {
            let batch = journal.beginBatch(title: "p\(b)", invoker: .user)
            for i in 0..<40 { journal.record(.created(path: .local("/x/\(b)-\(i)"), isDirectory: false), in: batch) }
        }
        // Przy starcie p3: 120 wpisów > 2×50 → bez p0; p3 dopisało potem swoje 40.
        #expect(journal.batches.map(\.title) == ["p1", "p2", "p3"])
        journal.beginBatch(title: "p4", invoker: .user)
        #expect(journal.batches.map(\.title) == ["p2", "p3", "p4"])
        #expect(journal.batch(journal.batches[0].id)?.title == "p2")
    }

    // MARK: 6. F6 w to samo miejsce przez dowiązanie katalogu

    @Test func moveOntoItselfThroughSymlinkedDirectoryIsSkipped() throws {
        let tmp = try TempDir()
        try tmp.file("real/a.txt", "a")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appending(path: "link").path, withDestinationPath: "real")
        let journal = OperationJournal()
        let batch = journal.beginBatch(title: "F6", invoker: .user)
        let engine = TransferEngine(request: TransferRequest(kind: .move, sources: [tmp.path.appending("link/a.txt")], destinationDirectory: tmp.path.appending("real")),
                                    journal: journal, batchID: batch)
        try engine.run()
        #expect(try tmp.read("real/a.txt") == "a")
        #expect(journal.batch(batch)?.entries.isEmpty == true)
        #expect(journal.lastUndoable() == nil)
    }

    // MARK: 7. Anulowanie odczytu fragmentu z archiwum

    @Test(.enabled(if: sevenZipPath != nil)) func sevenZipRangeReadIsCancelledWhileBlocked() throws {
        let tmp = try TempDir()
        // FIFO bez piszącego: 7zz blokuje się na otwarciu archiwum (jak przy długim rozpakowywaniu).
        let fifo = tmp.url.appending(path: "a.7z").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let started = ContinuousClock.now
        let cancelled = Flag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancelled.set() }
        let finished = finishes(within: .seconds(3), unblocking: fifo) {
            _ = try? SevenZip(executable: sevenZipPath!).read(.local(fifo), entry: "x", password: nil, range: 0..<10,
                                                              isCancelled: { cancelled.value })
        }
        #expect(finished, "odczyt nie zareagował na anulowanie (\(ContinuousClock.now - started))")
    }

    // MARK: 8. Ucięty ostatni wiersz dziennika

    @Test func truncatedLastJournalLineDoesNotEatNextLine() throws {
        let tmp = try TempDir()
        let file = tmp.url.appending(path: "ops.jsonl")
        let first = OperationJournal(fileURL: file)
        first.beginBatch(title: "pierwsza", invoker: .user)
        first.flush()
        // Awaria w trakcie zapisu: połowa wiersza bez znaku nowej linii.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"batch\":{\"id\":\"".utf8))
        try handle.close()

        let second = OperationJournal(fileURL: file)
        #expect(second.batches.map(\.title) == ["pierwsza"])
        second.beginBatch(title: "druga", invoker: .user)
        second.flush()
        #expect(OperationJournal(fileURL: file).batches.map(\.title) == ["pierwsza", "druga"])
    }

    // MARK: 9. Łączenie części

    /// Wiszące dowiązanie w miejscu wyniku: bez zapisu przez dowiązanie i bez usuwania go przy błędzie.
    @Test func joinDoesNotFollowDanglingSymlink() throws {
        let tmp = try TempDir()
        try tmp.file("x.001", "ab")
        try tmp.file("x.002", "cd")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appending(path: "x").path, withDestinationPath: "cel")
        #expect(throws: VFSError.self) {
            try FileSplitter.join([tmp.path.appending("x.001"), tmp.path.appending("x.002")], into: tmp.path.appending("x"))
        }
        #expect(!tmp.exists("cel"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: tmp.url.appending(path: "x").path)) == "cel")
        // Bez przeszkody łączy jak dotąd; błąd odczytu części usuwa tylko własny wynik.
        try FileSplitter.join([tmp.path.appending("x.001"), tmp.path.appending("x.002")], into: tmp.path.appending("y"))
        #expect(try tmp.read("y") == "abcd")
        #expect(throws: VFSError.self) {
            try FileSplitter.join([tmp.path.appending("x.001"), tmp.path.appending("brak.002")], into: tmp.path.appending("z"))
        }
        #expect(!tmp.exists("z"))
    }

    // MARK: 10. Partie zapisywane stopniowo

    /// Cmd+Z w trakcie zmiany atrybutów (tak samo tagów) wielu plików nie może cofać (i oznaczać) niepełnej partii.
    @Test func gradualBatchIsNotUndoableWhileRunning() async throws {
        let tmp = try TempDir()
        let count = 2_000
        let dir = try tmp.dir("duzo")
        for i in 0..<count { close(open(dir.path + "/f\(i)", O_WRONLY | O_CREAT | O_EXCL, 0o644)) }
        let journal = OperationJournal()
        let ops = FileOperations(journal: journal)
        let paths = (0..<count).map { dir.appending("f\($0)") }
        let sawUndoableRunning = Flag(), stop = Flag(), stopped = Flag()
        Thread.detachNewThread {
            while !stop.value {
                // Tylko lekkie odczyty (kopia partii przy każdym wpisie wymuszałaby kopiowanie tablicy wpisów).
                if let undoable = journal.lastUndoable(), undoable.entries.count < count { sawUndoableRunning.set() }
                usleep(200)
            }
            stopped.set()
        }
        try await ops.setAttributes(paths, AttributeChange(permissions: 0o600))
        stop.set()
        while !stopped.value { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!sawUndoableRunning.value)
        #expect(journal.lastUndoable()?.entries.count == count)
    }

    @Test func multiRenameBatchIsFinishedAfterExecute() throws {
        let tmp = try TempDir()
        try tmp.file("a.txt", "a")
        let journal = OperationJournal()
        let item = try LocalFS().itemSync(at: tmp.path.appending("a.txt"))
        let plan = MultiRename.plan([item], rule: RenameRule(nameMask: "[N]-nowy"))
        try MultiRename.execute(plan, journal: journal, invoker: .user, title: "MR")
        #expect(journal.lastUndoable()?.title == "MR")
    }

    // MARK: 11. Delegat testów

    /// Decyzja podana, zanim zadanie doszło do konfliktu, nie przepada (inaczej test wisi).
    @Test func blockingDelegateRemembersEarlyDecision() async {
        let delegate = BlockingDelegate()
        delegate.release(ConflictDecision(.skip))
        let item = FileItem(path: .local("/x/a"), name: "a", kind: .file)
        let decision = await delegate.resolveConflict(FileConflict(source: item, destination: item, kind: .copy))
        #expect(decision.resolution == .skip)
    }

    // MARK: 12. FIFO

    @Test func readingFIFODoesNotBlock() throws {
        let tmp = try TempDir()
        let fifo = tmp.url.appending(path: "kolejka").path
        #expect(mkfifo(fifo, 0o600) == 0)
        try tmp.file("zwykly.txt", "abc")
        let regular = tmp.path.appending("zwykly.txt"), special = VFSPath.local(fifo)
        let checks: [(String, @Sendable () -> Bool)] = [
            ("readSync", { (try? LocalFS().readSync(special)) == nil }),
            ("hash", { (try? Checksums.hash(special, algorithm: .sha256)) == nil }),
            ("binary", { (try? FileCompare.binary(regular, special)) == nil }),
            ("binary2", { (try? FileCompare.binary(special, regular)) == nil }),
        ]
        for (name, check) in checks {
            let failed = Flag()
            #expect(finishes(within: .seconds(3), unblocking: fifo) { if check() { failed.set() } }, "\(name) zablokował się na FIFO")
            #expect(failed.value, "\(name) przeczytał FIFO")
        }
        // Zwykłe pliki bez zmian.
        #expect(try LocalFS().readSync(tmp.path.appending("zwykly.txt")) == Data("abc".utf8))
        #expect(try FileCompare.binary(tmp.path.appending("zwykly.txt"), tmp.path.appending("zwykly.txt")).identical)
        #expect(try Checksums.hash(tmp.path.appending("zwykly.txt"), algorithm: .md5) == "900150983cd24fb0d6963f7d28e17f72")
    }
}

/// Uruchamia `body` na osobnym wątku i czeka najwyżej `limit`. Jeśli się nie skończy (blokada na FIFO),
/// otwiera FIFO do zapisu i zamyka je — czytelnik dostaje koniec pliku, więc wątek i procesy nie zostają.
func finishes(within limit: Duration, unblocking fifo: String, _ body: @escaping @Sendable () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { body(); done.signal() }
    let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
    if done.wait(timeout: .now() + seconds) == .success { return true }
    while done.wait(timeout: .now() + 0.05) == .timedOut {
        let fd = open(fifo, O_WRONLY | O_NONBLOCK)
        if fd >= 0 { close(fd) }
    }
    return false
}

final class Flag: Sendable {
    private let state = Atomic<Bool>(false)
    var value: Bool { state.load(ordering: .relaxed) }
    func set() { state.store(true, ordering: .relaxed) }
}
