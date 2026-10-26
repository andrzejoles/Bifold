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

# Hasła nie mogą trafić do argumentów procesów (widać je w `ps` i przez KERN_PROCARGS2) ani do zmiennych
# środowiskowych. WYJĄTEK: `security` nie umie czytać hasła pęku ani pliku .p12 z pliku czy deskryptora,
# a bez hasła w argumencie pyta w oknie/terminalu. Jedyna droga bez hasła w argumentach procesu to tryb
# `security -i`, który czyta polecenie ze standardowego wejścia (printf jest poleceniem wbudowanym
# powłoki, nie osobnym procesem). Jedno polecenie na wywołanie: wtedy kod wyjścia `security -i` jest
# kodem wyjścia polecenia, więc `set -e` działa jak zwykle.
# q: argument w cudzysłowie dla `security -i` (w cudzysłowie jedyne sekwencje specjalne to \\ i \").
q() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
sec() { printf '%s\n' "$1" | security -i; }

create_keychain() {
    local pw line kcs=()
    pw="$(openssl rand -hex 24)"
    sec "add-generic-password -U -s $(q "$SERVICE") -a bifold -w $(q "$pw") -T /usr/bin/security"
    sec "create-keychain -p $(q "$pw") $(q "$KC")"
    security set-keychain-settings "$KC"
    # Bez dopisywania do listy wyszukiwania użytkownika (codesign dostaje --keychain). Ścieżki mogą
    # zawierać spacje: `security list-keychains` wypisuje każdą w cudzysłowie, w osobnym wierszu.
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#\"}"; line="${line%\"}"
        case "$line" in ""|*bifold-signing*) ;; *) kcs+=("$line") ;; esac
    done < <(security list-keychains -d user)
    security list-keychains -d user -s ${kcs[@]+"${kcs[@]}"}
}

import_p12() {
    local file="$1" p12pw="$2" pw
    pw="$(password)"
    sec "unlock-keychain -p $(q "$pw") $(q "$KC")"
    sec "import $(q "$file") -k $(q "$KC") -P $(q "$p12pw") -T /usr/bin/codesign" >/dev/null
    sec "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $(q "$pw") $(q "$KC")" >/dev/null
}

# Nowa tożsamość w osobnej podpowłoce: pułapka EXIT usuwa katalog tymczasowy z niezaszyfrowanym kluczem
# (key.pem, -nodes) także przy błędzie (set -e) i przerwaniu; `trap … RETURN` tego nie robił.
create_identity() (
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    trap 'exit 130' INT TERM
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
    # Hasło .p12 przez standardowe wejście (-passout stdin), nie w argumentach.
    printf '%s\n' "$p12pw" | openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout stdin 2>/dev/null \
        || printf '%s\n' "$p12pw" | openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout stdin
    import_p12 "$tmp/id.p12" "$p12pw"
)

ensure() {
    if [ ! -f "$KC" ] || [ -z "$(password)" ]; then
        [ -f "$KC" ] && { echo "Jest $KC, ale brak hasła w pęku logowania — usuń plik albo użyj import" >&2; exit 1; }
        create_keychain
        create_identity
        echo "Utworzono tożsamość „${NAME}” w $KC" >&2
    fi
    sec "unlock-keychain -p $(q "$(password)") $(q "$KC")"
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
        sec "add-generic-password -U -s $(q "$SERVICE") -a bifold -w $(q "$PW") -T /usr/bin/security"
        sec "unlock-keychain -p $(q "$PW") $(q "$KC")"
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
