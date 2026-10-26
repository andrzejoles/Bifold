#!/usr/bin/env bash
# Instalatory macOS (Apple Silicon): dist/Bifold-X.Y.Z.dmg (przeciągnij do Aplikacji) i dist/Bifold-X.Y.Z.pkg
# (kreator instalacji do /Applications). Podpisana kopia robocza: dist/staging.noindex/Bifold-X.Y.Z.app
# (katalog .noindex — Spotlight i Launchpad nie pokazują jej jako kolejnej aplikacji).
# Podpis: stały certyfikat z własnym podpisem (scripts/signing.sh), żeby po aktualizacjach zostawały
# zgody macOS (Pełny dostęp do dysku, dostęp do haseł w Pęku kluczy).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(scripts/version.sh)"
BUILD="$(scripts/version.sh --build)"
DIST="$ROOT/dist"
APP_NAME="$(awk -F' = ' '/^BIFOLD_APP_NAME/{print $2}' Config/Brand.xcconfig)"
echo "=== $APP_NAME $VERSION ($BUILD) ==="

echo "[1/4] Budowanie (Release)…"
scripts/set-version.sh
# Jeden cel (bez ostrzeżenia o wielu pasujących) i tylko arm64 — ARCHS dotyczy też celów pakietów SPM.
xcodebuild -project Bifold.xcodeproj -scheme Bifold -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData.noindex -skipPackagePluginValidation -skipMacroValidation \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build -quiet
SRC="build/DerivedData.noindex/Build/Products/Release/$APP_NAME.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist")" = "$VERSION" ] \
    || { echo "BŁĄD: wersja w Info.plist nie zgadza się z $VERSION" >&2; exit 1; }

echo "[2/4] Podpis…"
mkdir -p "$DIST"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
APP="$DIST/staging.noindex/$APP_NAME-$VERSION.app"
rm -rf "$DIST/staging.noindex"
mkdir -p "$DIST/staging.noindex"
ditto "$SRC" "$APP"
# Dane dewelopera nie mogą trafić do instalatora.
LEAKED="$(find "$APP" \( -name "*.jsonl" -o -name "connections.json" -o -name "settings.json" -o -name "*.p12" -o -name "*.pem" \) -print)"
[ -z "$LEAKED" ] || { echo "BŁĄD: w pakiecie są pliki z danymi: $LEAKED" >&2; exit 1; }
scripts/third-party-licenses.sh "$APP/Contents/Resources/Licencje zewnętrzne.txt"
scripts/signing.sh sign "$APP"

echo "[3/4] PKG…"
PKG="$DIST/$APP_NAME-$VERSION.pkg"
PKGROOT="$(mktemp -d)"
trap 'rm -rf "$PKGROOT"' EXIT
ditto "$APP" "$PKGROOT/root/$APP_NAME.app"
pkgbuild --analyze --root "$PKGROOT/root" "$PKGROOT/component.plist" >/dev/null
# Bez „przenoszenia” do kopii aplikacji znalezionej gdzie indziej na dysku — zawsze /Applications.
plutil -replace 0.BundleIsRelocatable -bool NO "$PKGROOT/component.plist"
pkgbuild --root "$PKGROOT/root" --component-plist "$PKGROOT/component.plist" --install-location /Applications \
    --identifier "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist").pkg" \
    --version "$VERSION" "$PKG" >/dev/null

echo "[4/4] DMG…"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$PKGROOT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Aplikacje (Applications)"
cp "$APP/Contents/Resources/Licencje zewnętrzne.txt" "$STAGE/"
cp LICENSE "$STAGE/LICENSE.txt"
cat > "$STAGE/Instrukcja instalacji.txt" <<TXT
$APP_NAME $VERSION — dwupanelowy menedżer plików dla macOS (Apple Silicon, macOS 27)
Autor: Andrzej Oleś w kooperacji z Claude AI · licencja MIT · https://github.com/$(awk -F' = ' '/^BIFOLD_REPOSITORY/{print $2}' Config/Brand.xcconfig)

INSTALACJA
1. Przeciągnij „${APP_NAME}” na „Aplikacje (Applications)”.
2. Pierwsze uruchomienie: aplikacja nie jest notaryzowana przez Apple, więc macOS ją zablokuje.
   Otwórz Ustawienia systemowe → Prywatność i ochrona → „Otwórz mimo to”.
   (W Terminalu: xattr -dr com.apple.quarantine /Applications/$APP_NAME.app)
3. Pełny dostęp do dysku: aplikacja przy starcie pokaże, jak go nadać (zalecane dla menedżera plików).

NARZĘDZIA (Homebrew, https://brew.sh)
  brew install ripgrep sevenzip rclone            # wyszukiwanie w treści, archiwa, serwery i chmury
  brew install libmtp libimobiledevice            # opcjonalnie: Android (MTP) i iPhone
  Agenci AI (opcjonalnie): Claude Code, Codex, Grok, Antigravity — każdy instalujesz osobno.

AKTUALIZACJE
  Aplikacja raz dziennie sprawdza nowe wydania i instaluje je sama (menu $APP_NAME → Sprawdź uaktualnienia…).
  Każde wydanie jest podpisane kluczem autora (EdDSA) — aplikacja nie przyjmie pliku z innego źródła.
TXT
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

# Kopie robocze nie mają się pojawiać w systemie jako osobne aplikacje.
"$LSREGISTER" -u "$ROOT/$SRC" 2>/dev/null || true
"$LSREGISTER" -u "$APP" 2>/dev/null || true

echo "Gotowe:"
ls -lh "$DMG" "$PKG"
shasum -a 256 "$DMG" "$PKG"
