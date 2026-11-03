import Darwin
import Foundation

/// Deskryptory, które nie mogą przejść do programów uruchamianych przez aplikację.
///
/// `posix_spawn` w `Spawn` i `Foundation.Process` zamykają w procesie potomnym wszystko poza 0–2, ale
/// terminale (SwiftTerm: `forkpty` + `execve`) dziedziczą każdy deskryptor bez `FD_CLOEXEC` — powłoka,
/// `ssh` w karcie-terminalu i CLI agenta dostawałyby gniazdo nasłuchujące serwera agenta, połączenia
/// innych sesji agenta i końce potoków procesów w tle (potok bez zamkniętego końca nie kończy się EOF).
public enum FileDescriptors {
    /// Ustawia `FD_CLOEXEC` na deskryptorze (zwraca go, żeby dało się użyć w wyrażeniu).
    @discardableResult
    public static func closeOnExec(_ fd: Int32) -> Int32 {
        guard fd >= 0 else { return fd }
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0, flags & FD_CLOEXEC == 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        return fd
    }

    public static func isCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC != 0
    }

    /// Otwarte deskryptory procesu (`proc_pidinfo(PROC_PIDLISTFDS)`), bez przeglądania całej tablicy.
    public static func openDescriptors() -> [Int32] {
        let pid = getpid()
        let entry = MemoryLayout<proc_fdinfo>.stride
        var capacity = max(64, Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)) / entry + 32)
        while true {
            var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let bytes = buffer.withUnsafeMutableBytes { raw in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
            }
            guard bytes > 0 else { return [] }
            let count = Int(bytes) / entry
            // Pełny bufor — mogło się nie zmieścić (deskryptory otwierane w międzyczasie).
            if count < capacity { return buffer.prefix(count).map(\.proc_fd) }
            capacity *= 2
        }
    }

    /// Oznacza `FD_CLOEXEC` wszystkie deskryptory poza 0–2. Wywoływane tuż przed uruchomieniem procesu,
    /// który nie zamyka deskryptorów sam (terminal SwiftTerm). Aplikacji to nie zmienia: własne procesy
    /// i tak uruchamia przez `posix_spawn` z `POSIX_SPAWN_CLOEXEC_DEFAULT`.
    public static func markAllCloseOnExec() {
        for fd in openDescriptors() where fd > 2 { closeOnExec(fd) }
    }
}
