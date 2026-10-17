#!/usr/bin/env bash
# Zapisuje wersję i numer kompilacji z gita do build/Version.xcconfig (dołączany przez Config/Brand.xcconfig).
# Uruchamiany przed budowaniem: akcja wstępna schematu w Xcode, Makefile i scripts/build-installer.sh.
# Numeru wersji nie ma nigdzie w repozytorium.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/build"
OUT="$ROOT/build/Version.xcconfig"
NEW="MARKETING_VERSION = $("$ROOT/scripts/version.sh")
CURRENT_PROJECT_VERSION = $("$ROOT/scripts/version.sh" --build)"
# Bez zmiany pliku, gdy wersja ta sama (inaczej Xcode przebudowuje wszystko).
[ -f "$OUT" ] && [ "$(cat "$OUT")" = "$NEW" ] || printf '%s\n' "$NEW" > "$OUT"
