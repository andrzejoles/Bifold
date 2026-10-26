import Foundation
import Testing
@testable import BifoldCore

@Suite struct FileCompareTests {
    @Test func textDiff() {
        let r = FileCompare.text("a\nb\nc\nd", "a\nB\nc\nd\ne")
        #expect(r.removed == 1 && r.added == 2)
        #expect(r.lines.map(\.kind) == [.same, .removed, .added, .same, .same, .added])
        let u = FileCompare.unified(r, leftName: "x", rightName: "y")
        #expect(u.contains("-b\n+B") && u.contains("+e"))
        #expect(FileCompare.text("same", "same").identical)
    }

    @Test func binaryCompare() throws {
        let tmp = try TempDir()
        let a = tmp.url.appending(path: "a.bin"), b = tmp.url.appending(path: "b.bin")
        var data = Data(repeating: 1, count: 3_000_000)
        try data.write(to: a)
        data[2_500_000] = 9
        try data.write(to: b)
        let r = try FileCompare.binary(.local(a), .local(b))
        #expect(!r.identical && r.firstDifference == 2_500_000 && r.differingBytes == 1)
        #expect(try FileCompare.binary(.local(a), .local(a)).identical)
        try Data(repeating: 1, count: 10).write(to: b)
        #expect(try FileCompare.binary(.local(a), .local(b)).firstDifference == 10)
    }

    @Test func directoryCompare() {
        let old = Date(timeIntervalSince1970: 1_000_000), new = Date(timeIntervalSince1970: 2_000_000)
        func f(_ n: String, _ d: Date, _ s: Int64 = 1) -> FileItem { FileItem(path: .local("/x/" + n), kind: .file, size: s, modified: d) }
        let r = DirectoryCompare.compare(left: [f("a", old), f("b", new), f("same", old), f("tylkoL", old)],
                                         right: [f("a", new), f("b", old), f("same", old), f("tylkoP", old)])
        #expect(r.onlyLeft == ["tylkoL"] && r.onlyRight == ["tylkoP"])
        #expect(r.newerLeft == ["b"] && r.newerRight == ["a"] && r.identical == 1)
        #expect(r.markLeft == ["tylkoL", "b"] && r.markRight == ["tylkoP", "a"])
    }

    /// Ścieżki z serwera z niebezpiecznymi składnikami nie są składane z lokalnym korzeniem.
    @Test func syncRejectsUnsafePaths() throws {
        #expect(SyncPlanner.isSafeRelativePath("kat/plik.txt"))
        for bad in ["../x.txt", "kat/../../x", "/etc/hosts", "a//b", "./a", "kat/zły\nplik", ""] {
            #expect(!SyncPlanner.isSafeRelativePath(bad), "\(bad)")
        }
        let tmp = try TempDir()
        try tmp.file("poza.txt", "nie ruszać")
        let root = try tmp.dir("cel")
        let plan = SyncPlan(sourceFs: "/zrodlo", destinationFs: root.path, mode: .mirror,
                            actions: [SyncAction(kind: .deleteFromDestination, path: "../poza.txt", reason: "")], identical: 0,
                            localSource: nil, localDestination: root)
        // rclone nie jest potrzebny: niebezpieczna ścieżka odpada przed jakimkolwiek wywołaniem.
        let errors = try SyncPlanner.execute(plan, rclone: Rclone(executable: "/nonexistent", socket: URL(filePath: "/tmp/bifold-nie-ma.sock")),
                                             control: JobControl(), journal: nil, batchID: nil) { _ in }
        #expect(errors.count == 1)
        #expect(try tmp.read("poza.txt") == "nie ruszać")
    }
}

@Suite(.serialized, .enabled(if: rclonePath != nil)) struct SyncTests {
    func rclone() throws -> Rclone {
        let r = Rclone(executable: rclonePath!, socket: URL(filePath: "/tmp/bfs-\(UUID().uuidString.prefix(6)).sock"))
        try r.start()
        return r
    }

    func fixture() throws -> (TempDir, VFSPath, VFSPath) {
        let tmp = try TempDir()
        try tmp.file("A/rowne.txt", "1", modified: Date(timeIntervalSince1970: 1_600_000_000))
        try tmp.file("B/rowne.txt", "1", modified: Date(timeIntervalSince1970: 1_600_000_000))
        try tmp.file("A/tylkoA.txt", "a")
        try tmp.file("A/pod/gleboko.txt", "g")
        try tmp.file("B/tylkoB.txt", "b")
        try tmp.file("A/rozne.txt", "nowsze w A", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try tmp.file("B/rozne.txt", "starsze", modified: Date(timeIntervalSince1970: 1_650_000_000))
        return (tmp, tmp.path.appending("A"), tmp.path.appending("B"))
    }

    @MainActor @Test(arguments: SyncMode.allCases)
    func planAndExecuteLocal(mode: SyncMode) async throws {
        let (tmp, a, b) = try fixture()
        let rc = try rclone()
        defer { rc.stop() }
        let plan = try await SyncPlanner.plan(rclone: rc, sourceFs: a.path, destinationFs: b.path, mode: mode, localSource: a, localDestination: b)
        // Podgląd niczego nie zmienia.
        #expect(!tmp.exists("B/tylkoA.txt"))
        let kinds = Dictionary(plan.actions.map { ($0.path, $0.kind) }, uniquingKeysWith: { a, _ in a })
        #expect(kinds["tylkoA.txt"] == .copyToDestination && kinds["pod/gleboko.txt"] == .copyToDestination)
        #expect(kinds["rozne.txt"] == .copyToDestination)
        #expect(kinds["rowne.txt"] == nil && plan.identical == 1)
        switch mode {
        case .mirror: #expect(kinds["tylkoB.txt"] == .deleteFromDestination)
        case .update: #expect(kinds["tylkoB.txt"] == nil)
        case .twoWay: #expect(kinds["tylkoB.txt"] == .copyToSource)
        }

        let journal = OperationJournal()
        let queue = JobQueue(journal: journal)
        let job = queue.enqueue(.sync(plan, rc), title: "sync")
        #expect(await queue.wait(for: job) == .completed, "\(job.errors)")
        #expect(try tmp.read("B/pod/gleboko.txt") == "g")
        #expect(try tmp.read("B/rozne.txt") == "nowsze w A")
        switch mode {
        case .mirror: #expect(!tmp.exists("B/tylkoB.txt"))
        case .update: #expect(tmp.exists("B/tylkoB.txt") && !tmp.exists("A/tylkoB.txt"))
        case .twoWay: #expect(try tmp.read("A/tylkoB.txt") == "b")
        }
        // Po synchronizacji (poza aktualizacją dwukierunkową — wtedy też) różnic w kierunku źródło→cel nie ma.
        let again = try await SyncPlanner.plan(rclone: rc, sourceFs: a.path, destinationFs: b.path, mode: mode, localSource: a, localDestination: b)
        #expect(again.actions.filter { $0.kind == .copyToDestination }.isEmpty)

        // Cofnięcie: nadpisany/usunięty plik wraca z Kosza, kopie znikają.
        let undo = UndoPlanner.plan(for: journal.batches)
        _ = UndoPlanner.execute(undo, journal: journal, force: true)
        #expect(try tmp.read("B/rozne.txt") == "starsze")
        #expect(!tmp.exists("B/tylkoA.txt"))
        #expect(tmp.exists("B/tylkoB.txt"))
    }

    @Test func excludedActionsAreSkipped() async throws {
        let (tmp, a, b) = try fixture()
        let rc = try rclone()
        defer { rc.stop() }
        var plan = try await SyncPlanner.plan(rclone: rc, sourceFs: a.path, destinationFs: b.path, mode: .update, localSource: a, localDestination: b)
        for i in plan.actions.indices where plan.actions[i].path == "rozne.txt" { plan.actions[i].enabled = false }
        _ = try SyncPlanner.execute(plan, rclone: rc, control: JobControl(), journal: nil, batchID: nil) { _ in }
        #expect(try tmp.read("B/rozne.txt") == "starsze")
        #expect(tmp.exists("B/tylkoA.txt"))
    }
}

@Suite(.serialized, .enabled(if: rclonePath != nil)) struct SyncByContentTests {
    @Test func checksumModeFindsSameSizeDifferences() async throws {
        let tmp = try TempDir()
        let d = Date(timeIntervalSince1970: 1_600_000_000)
        try tmp.file("A/x.txt", "aaaa", modified: d)
        try tmp.file("B/x.txt", "bbbb", modified: d)
        let rc = Rclone(executable: rclonePath!, socket: URL(filePath: "/tmp/bfc-\(UUID().uuidString.prefix(6)).sock"))
        try rc.start()
        defer { rc.stop() }
        let quick = try await SyncPlanner.plan(rclone: rc, sourceFs: tmp.url.path + "/A", destinationFs: tmp.url.path + "/B", mode: .update, localSource: nil, localDestination: nil)
        #expect(quick.actions.isEmpty && quick.identical == 1)
        let deep = try await SyncPlanner.plan(rclone: rc, sourceFs: tmp.url.path + "/A", destinationFs: tmp.url.path + "/B", mode: .update, localSource: nil, localDestination: nil, byContent: true)
        #expect(deep.actions.map(\.path) == ["x.txt"])
    }
}
