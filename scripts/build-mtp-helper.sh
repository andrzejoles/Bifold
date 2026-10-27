#!/usr/bin/env bash
# Buduje pomocnika bifold-mtp (telefony z Androidem) z libmtp z Homebrew do ThirdParty/build/bifold-mtp.
# Biblioteka jest linkowana dynamicznie z /opt/homebrew (nie trafia do aplikacji — użytkownik instaluje
# ją sam: brew install libmtp). Bez libmtp pomocnik nie powstaje, a Bifold zgłasza brak libmtp.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Tools/bifold-mtp/bifold-mtp.c"
OUT="$ROOT/ThirdParty/build/bifold-mtp"
PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
if [ ! -f "$PREFIX/include/libmtp.h" ]; then
    echo "warning: brak libmtp ($PREFIX/include/libmtp.h) — bifold-mtp nie zostanie zbudowany (brew install libmtp)"
    rm -f "$OUT"
    exit 0
fi
mkdir -p "$(dirname "$OUT")"
# libmtp.dylib to dowiązanie (Cellar/libmtp/<wersja>) — porównujemy datę pliku docelowego, żeby
# `brew upgrade libmtp` przebudował pomocnika.
LIB="$(realpath "$PREFIX/lib/libmtp.dylib" 2>/dev/null || true)"
if [ ! -x "$OUT" ] || [ "$SRC" -nt "$OUT" ] || [ "${BASH_SOURCE[0]}" -nt "$OUT" ] \
    || { [ -n "$LIB" ] && [ "$LIB" -nt "$OUT" ]; }; then
    clang -O2 -Wall -arch arm64 -mmacosx-version-min=27.0 -I"$PREFIX/include" -L"$PREFIX/lib" -lmtp "$SRC" -o "$OUT"
fi
