#!/usr/bin/env bash
# Narzędzia Sparkle z pakietu (generate_keys, sign_update, generate_appcast) z kontem klucza „bifold”
# w Pęku kluczy. Przykłady:
#   scripts/sparkle-tools.sh generate_keys -p            # klucz publiczny (do Config/Brand.xcconfig)
#   scripts/sparkle-tools.sh generate_keys -x klucz.txt  # kopia zapasowa klucza prywatnego — poza repozytorium!
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${1:?Podaj narzędzie: generate_keys, sign_update albo generate_appcast}"
shift
BIN="$ROOT/build/DerivedData.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$BIN/$TOOL" ]; then
    xcodebuild -project "$ROOT/Bifold.xcodeproj" -scheme Bifold -derivedDataPath "$ROOT/build/DerivedData.noindex" \
        -resolvePackageDependencies -skipPackagePluginValidation >/dev/null
fi
case "$TOOL" in
    generate_appcast|sign_update)
        # Klucz eksportuje generate_keys (ma dostęp do swojego wpisu w Pęku kluczy bez pytania; inne
        # narzędzie wywołałoby okno zgody) do prywatnego katalogu tymczasowego, usuwanego od razu po użyciu.
        KEYDIR="$(mktemp -d)"
        chmod 700 "$KEYDIR"
        trap 'rm -rf "$KEYDIR"' EXIT
        "$BIN/generate_keys" --account bifold -x "$KEYDIR/key" >/dev/null
        "$BIN/$TOOL" --ed-key-file "$KEYDIR/key" "$@"
        ;;
    *)
        exec "$BIN/$TOOL" --account bifold "$@"
        ;;
esac
