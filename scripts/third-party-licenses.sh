#!/usr/bin/env bash
# Teksty licencji bibliotek dołączanych do aplikacji (pakiety SPM i HexFiend) w jednym pliku.
# Programy uruchamiane jako osobne procesy (7-Zip, rclone, ripgrep, libmtp, libimobiledevice) nie są
# dołączane — użytkownik instaluje je sam (Homebrew).
# Użycie: scripts/third-party-licenses.sh plik_wyjściowy
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?Podaj plik wyjściowy}"
{
    echo "Bifold — licencje bibliotek zewnętrznych"
    echo "========================================"
    echo
    echo "Bifold: licencja MIT, © 2026 Andrzej Oleś w kooperacji z Claude AI (plik LICENSE w repozytorium)."
    for f in "$ROOT/ThirdParty/HexFiend/License.txt" "$ROOT"/build/DerivedData.noindex/SourcePackages/checkouts/*/{LICENSE,LICENSE.txt,LICENSE.md,NOTICE,NOTICE.txt}; do
        [ -f "$f" ] || continue
        name="$(basename "$(dirname "$f")")"
        echo
        echo "----------------------------------------------------------------------"
        echo "$name — $(basename "$f")"
        echo "----------------------------------------------------------------------"
        cat "$f"
    done
} > "$OUT"
