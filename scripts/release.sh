#!/usr/bin/env bash
# Wydanie: instalatory, archiwum dla Sparkle, appcast.xml podpisany kluczem EdDSA i SZKIC wydania na GitHubie
# (jak w CantatePresenter). Publikacja po sprawdzeniu szkicu: gh release edit vX.Y.Z --draft=false.
# Zainstalowane kopie pobiorą aktualizację same dopiero po publikacji (kanał: releases/latest/download/appcast.xml).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "Wydanie tylko z gałęzi main" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Najpierw zatwierdź zmiany" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse origin/main)" = "$(git rev-parse HEAD)" ] || { echo "Najpierw zsynchronizuj main z GitHubem (git pull / git push)" >&2; exit 1; }

VERSION="$(scripts/version.sh)"
TAG="v$VERSION"
REPO="$(awk -F' = ' '/^BIFOLD_REPOSITORY/{print $2}' Config/Brand.xcconfig)"
APP_NAME="$(awk -F' = ' '/^BIFOLD_APP_NAME/{print $2}' Config/Brand.xcconfig)"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Wydanie $TAG już istnieje" >&2
    exit 1
fi

scripts/build-installer.sh

RELEASE_DIR="$ROOT/dist/release-$VERSION"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
# Archiwum dla Sparkle: tylko ono w katalogu, bo generate_appcast czyta wszystkie archiwa.
ditto "dist/$APP_NAME-$VERSION.app" "$RELEASE_DIR/stage/$APP_NAME.app"
ditto -c -k --sequesterRsrc --keepParent "$RELEASE_DIR/stage/$APP_NAME.app" "$RELEASE_DIR/$APP_NAME-$VERSION.zip"
rm -rf "$RELEASE_DIR/stage"
scripts/sparkle-tools.sh generate_appcast \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO/releases/tag/$TAG" \
    "$RELEASE_DIR"

PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
{
    echo "$APP_NAME $VERSION"
    echo
    # Zmiany wchodzą na main przez scalenia PR: tytuł PR jest w treści commita scalającego.
    git log --first-parent --format='%s%n%b' ${PREVIOUS:+"$PREVIOUS..HEAD"} \
        | awk '/^Merge pull request #[0-9]+ from /{n=$4; next} n!="" && NF{print "- " $0 " (" n ")"; n=""}' | head -40 || true
    cat <<NOTES

## Instalacja (macOS 27, Apple Silicon)
Pobierz \`$APP_NAME-$VERSION.dmg\` i przeciągnij aplikację do Aplikacji (albo uruchom \`$APP_NAME-$VERSION.pkg\`).
Aplikacja nie jest notaryzowana: przy pierwszym uruchomieniu Ustawienia systemowe → Prywatność i ochrona → „Otwórz mimo to”.
Zainstalowane kopie aktualizują się same. Narzędzia: \`brew install ripgrep sevenzip rclone\` (szczegóły w README).

Pliki \`$APP_NAME-$VERSION.zip\` i \`appcast.xml\` służą automatycznym aktualizacjom.

Autor: Andrzej Oleś w kooperacji z Claude AI · licencja MIT
NOTES
} > "$RELEASE_DIR/notes.md"

git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" --draft --title "$APP_NAME $VERSION" --notes-file "$RELEASE_DIR/notes.md" \
    "$RELEASE_DIR/$APP_NAME-$VERSION.zip" "$RELEASE_DIR/appcast.xml" "dist/$APP_NAME-$VERSION.dmg" "dist/$APP_NAME-$VERSION.pkg"
echo "Szkic wydania $TAG gotowy. Sprawdź go na GitHubie i opublikuj: gh release edit $TAG --draft=false"
