#!/usr/bin/env bash
# Zapisuje wersję i numer kompilacji z gita do build/Version.xcconfig (dołączany przez Config/Brand.xcconfig).
# Uruchamiany przed budowaniem: akcja wstępna schematu w Xcode, Makefile i scripts/build-installer.sh.
# Numeru wersji nie ma nigdzie w repozytorium.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/build"
OUT="$ROOT/build/Version.xcconfig"
# Czyste środowisko (jak w build-hexfiend.sh): akcja wstępna schematu dostaje zmienne budowania Xcode,
# a git Apple (przez xcrun) odpowiada na SWIFT_DEBUG_INFORMATION_* „Warning: unknown environment variable”.
version() {
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} \
        "$ROOT/scripts/version.sh" "$@"
}
NEW="MARKETING_VERSION = $(version)
CURRENT_PROJECT_VERSION = $(version --build)"
# Bez zmiany pliku, gdy wersja ta sama (inaczej Xcode przebudowuje wszystko).
[ -f "$OUT" ] && [ "$(cat "$OUT")" = "$NEW" ] || printf '%s\n' "$NEW" > "$OUT"
