import CoreServices
import Foundation

/// Atrybut kwarantanny (`com.apple.quarantine`) dla plików pobranych z serwerów i telefonów — jak
/// przeglądarka: program albo skrypt z wrogiego serwera nie uruchomi się bez Gatekeepera.
enum Quarantine {
    /// Oznacza element i (dla katalogu) całą jego zawartość; dowiązań nie dotyka (atrybut trafiłby
    /// do celu dowiązania). `changedSince` — tylko elementy utworzone/zapisane od tej chwili (ctime),
    /// żeby nie oznaczyć plików użytkownika w scalanym katalogu. Błędy pomijane — brak atrybutu nie
    /// może przerwać kopiowania.
    static func mark(_ path: String, changedSince: Date? = nil) {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT != S_IFLNK else { return }
        if isRecent(st, changedSince) { set(path) }
        guard st.st_mode & S_IFMT == S_IFDIR, let walker = FileManager.default.enumerator(atPath: path) else { return }
        while let relative = walker.nextObject() as? String {
            let child = path + "/" + relative
            var cs = stat()
            guard lstat(child, &cs) == 0, cs.st_mode & S_IFMT != S_IFLNK else { continue }
            if isRecent(cs, changedSince) { set(child) }
        }
    }

    private static func isRecent(_ st: stat, _ since: Date?) -> Bool {
        guard let since else { return true }
        return Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec) / 1e9 >= since.timeIntervalSince1970
    }

    static var agentName: String {
        Bundle.main.object(forInfoDictionaryKey: "BifoldAppName") as? String ?? ProcessInfo.processInfo.processName
    }

    private static func set(_ path: String) {
        var url = URL(filePath: path)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: agentName,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineTimeStampKey as String: Date(),
        ]
        try? url.setResourceValues(values)
    }

    /// Do testów: czy element ma atrybut kwarantanny.
    static func isMarked(_ path: String) -> Bool {
        (try? URL(filePath: path).resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil
    }
}
