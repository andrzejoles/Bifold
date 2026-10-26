#!/usr/bin/env bash
# Teksty licencji bibliotek dołączanych do aplikacji (pakiety SPM i HexFiend) w jednym pliku.
# Programy uruchamiane jako osobne procesy (7-Zip, rclone, ripgrep, libmtp, libimobiledevice) nie są
# dołączane — użytkownik instaluje je sam (Homebrew).
# Użycie: scripts/third-party-licenses.sh plik_wyjściowy
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?Podaj plik wyjściowy}"
CHECKOUTS="$ROOT/build/DerivedData.noindex/SourcePackages/checkouts"

# Pakiety SPM linkowane z aplikacją (statycznie do programu albo jako framework) — sprawdzone w
# Bifold.LinkFileList i Contents/Frameworks: SwiftTerm, Sparkle, MCP (swift-sdk) i jego zależności
# Logging (swift-log), SystemPackage (swift-system), EventSource (eventsource).
LINKED=(SwiftTerm Sparkle swift-sdk swift-log swift-system eventsource)
# Pobierane przez SPM, ale używane tylko przez cele, których aplikacja nie buduje na macOS (narzędzia
# i testy zależności, cechy pakietów wyłączone domyślnie) — nie trafiają do pakietu aplikacji.
NOT_LINKED=(swift-nio swift-collections swift-atomics swift-argument-parser swift-png h)

contains() { local x="$1"; shift; local e; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }

# Nowy pakiet w zależnościach musi trafić na jedną z list (lepiej dołączyć licencję za dużo niż za mało).
for d in "$CHECKOUTS"/*/; do
    name="$(basename "$d")"
    contains "$name" "${LINKED[@]}" "${NOT_LINKED[@]}" \
        || { echo "BŁĄD: nieznany pakiet SPM „$name” — dopisz go do LINKED albo NOT_LINKED w $0" >&2; exit 1; }
done

section() {
    echo
    echo "----------------------------------------------------------------------"
    echo "$1 — $(basename "$2")"
    echo "----------------------------------------------------------------------"
    cat "$2"
}

{
    echo "Bifold — licencje bibliotek zewnętrznych"
    echo "========================================"
    echo
    echo "Bifold: licencja MIT, © 2026 Andrzej Oleś w kooperacji z Claude AI (plik LICENSE w repozytorium)."
    section HexFiend "$ROOT/ThirdParty/HexFiend/License.txt"
    for name in "${LINKED[@]}"; do
        found=0
        for f in "$CHECKOUTS/$name"/{LICENSE,LICENSE.txt,LICENSE.md,NOTICE,NOTICE.txt}; do
            [ -f "$f" ] || continue
            section "$name" "$f"
            found=1
        done
        [ "$found" = 1 ] || { echo "BŁĄD: brak pliku licencji pakietu $name w $CHECKOUTS" >&2; exit 1; }
    done
} > "$OUT"
