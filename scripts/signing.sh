#!/usr/bin/env bash
# Stały podpis aplikacji certyfikatem z własnym podpisem („Bifold Self-Signed”).
#
# Po co: podpis ad-hoc zmienia się przy każdej kompilacji, a macOS wiąże z podpisem Pełny dostęp do
# dysku i dostęp do haseł w Pęku kluczy — po każdej aktualizacji trzeba by je nadawać od nowa.
# Z tym certyfikatem wymaganie podpisu to „identyfikator + certyfikat”, więc nadane zgody zostają.
# To nie zastępuje Developer ID: Gatekeeper i tak pokaże ostrzeżenie przy pierwszym uruchomieniu.
#
# Certyfikat i klucz prywatny są w osobnym pęku kluczy ~/Library/Keychains/bifold-signing.keychain-db
# (hasło losowe, zapisane w pęku logowania jako „bifold-signing-keychain”). Nic z tego nie trafia do repozytorium.
#
# Użycie: scripts/signing.sh ensure            tworzy tożsamość (raz)
#         scripts/signing.sh sign Bifold.app   podpisuje pakiet od środka
#         scripts/signing.sh export KATALOG    kopia zapasowa (pęk kluczy + jego hasło) — poza repozytorium!
#         scripts/signing.sh restore KATALOG   odtworzenie z kopii (np. na nowym Macu)
#         scripts/signing.sh import plik.p12   tożsamość z pliku .p12 (np. własny certyfikat)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC="$HOME/Library/Keychains/bifold-signing.keychain-db"
NAME="Bifold Self-Signed"
SERVICE="bifold-signing-keychain"

password() { security find-generic-password -s "$SERVICE" -a bifold -w 2>/dev/null; }

create_keychain() {
    local pw
    pw="$(openssl rand -hex 24)"
    security add-generic-password -U -s "$SERVICE" -a bifold -w "$pw" -T /usr/bin/security
    security create-keychain -p "$pw" "$KC"
    security set-keychain-settings "$KC"
    # Bez dopisywania do listy wyszukiwania użytkownika (codesign dostaje --keychain).
    security list-keychains -d user -s $(security list-keychains -d user | tr -d '"' | grep -v bifold-signing)
}

import_p12() {
    local file="$1" p12pw="$2"
    security unlock-keychain -p "$(password)" "$KC"
    security import "$file" -k "$KC" -P "$p12pw" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(password)" "$KC" >/dev/null
}

ensure() {
    if [ ! -f "$KC" ] || [ -z "$(password)" ]; then
        [ -f "$KC" ] && { echo "Jest $KC, ale brak hasła w pęku logowania — usuń plik albo użyj import" >&2; exit 1; }
        create_keychain
        local tmp p12pw
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' RETURN
        p12pw="$(openssl rand -hex 16)"
        cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
O=Bifold
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
        openssl req -x509 -newkey rsa:3072 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 7300 -config "$tmp/cert.cnf" 2>/dev/null
        openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout "pass:$p12pw" 2>/dev/null \
            || openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout "pass:$p12pw"
        import_p12 "$tmp/id.p12" "$p12pw"
        echo "Utworzono tożsamość „${NAME}” w $KC" >&2
    fi
    security unlock-keychain -p "$(password)" "$KC"
}

identity() {
    security find-identity -p codesigning "$KC" | awk -v n="\"$NAME\"" 'index($0, n) {print $2; exit}'
}

sign_one() {
    codesign --force --sign "$ID" --keychain "$KC" --timestamp=none --preserve-metadata=identifier,entitlements,flags "$@"
}

case "${1:-}" in
    ensure)
        ensure
        identity
        ;;
    sign)
        APP="${2:?Podaj ścieżkę do Bifold.app}"
        ensure
        ID="$(identity)"
        [ -n "$ID" ] || { echo "Brak tożsamości ${NAME}" >&2; exit 1; }
        # Od środka: części Sparkle, frameworki, programy pomocnicze, na końcu pakiet.
        SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
        if [ -d "$SPARKLE" ]; then
            for x in "$SPARKLE"/XPCServices/*.xpc; do [ -e "$x" ] && sign_one "$x"; done
            sign_one "$SPARKLE/Autoupdate"
            sign_one "$SPARKLE/Updater.app"
            sign_one "$APP/Contents/Frameworks/Sparkle.framework"
        fi
        for f in "$APP"/Contents/Frameworks/*.framework; do
            [ "$(basename "$f")" = "Sparkle.framework" ] || sign_one "$f"
        done
        for exe in "$APP"/Contents/MacOS/*; do
            [ "$(basename "$exe")" = "$(defaults read "$APP/Contents/Info" CFBundleExecutable)" ] || sign_one "$exe"
        done
        sign_one "$APP"
        codesign --verify --deep --strict "$APP"
        codesign -d -r- "$APP" 2>&1 | grep designated
        ;;
    export)
        # Kopia całego pęku (zaszyfrowany swoim hasłem) i hasła — bez eksportu klucza, który
        # wymagałby okna zgody z hasłem pęku.
        DIR="${2:?Podaj katalog kopii}"
        mkdir -p -m 700 "$DIR"
        ensure >/dev/null
        (umask 077
         cp -p "$KC" "$DIR/bifold-signing.keychain-db"
         password > "$DIR/bifold-signing-haslo-pęku.txt"
         chmod 600 "$DIR/bifold-signing.keychain-db" "$DIR/bifold-signing-haslo-pęku.txt")
        echo "Zapisano w $DIR — przechowuj poza repozytorium (np. menedżer haseł, zaszyfrowany dysk)."
        ;;
    restore)
        DIR="${2:?Podaj katalog kopii}"
        [ ! -f "$KC" ] || { echo "Już jest $KC — najpierw go usuń, jeśli chcesz odtworzyć kopię" >&2; exit 1; }
        PW="$(cat "$DIR/bifold-signing-haslo-pęku.txt")"
        cp -p "$DIR/bifold-signing.keychain-db" "$KC"
        security add-generic-password -U -s "$SERVICE" -a bifold -w "$PW" -T /usr/bin/security
        security unlock-keychain -p "$PW" "$KC"
        identity
        ;;
    import)
        FILE="${2:?Podaj plik .p12}"
        [ -f "$KC" ] || create_keychain
        read -r -s -p "Hasło do pliku $FILE: " P12PW; echo
        import_p12 "$FILE" "$P12PW"
        identity
        ;;
    *)
        echo "Użycie: $0 ensure | sign Bifold.app | export KATALOG | restore KATALOG | import plik.p12" >&2
        exit 2
        ;;
esac
