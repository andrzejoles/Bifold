# Wydania i aktualizacje

## Wersja

Numer wersji nie jest nigdzie zapisany ręcznie (reguła jak w CantatePresenter, `scripts/version.sh`):
`GŁÓWNY.ŚRODKOWY.OSTATNI` = `1 + PR/10 . PR mod 10 . commity od ostatniego scalonego PR`.
8 PR + 3 commity → 1.8.3, 10 PR → 2.0.0. Numer kompilacji (`CFBundleVersion`) = liczba wszystkich
commitów — rośnie z każdym wydaniem, czego wymaga Sparkle. Zmiany wchodzą na `main` przez PR scalane
zwykłym „Merge pull request” (nie squash), inaczej się nie policzą. `make version` wypisuje wersję.

Przed budowaniem `scripts/set-version.sh` zapisuje wersję do `build/Version.xcconfig`
(akcja wstępna schematu w Xcode, `make build`, `scripts/build-installer.sh`).

## Podpis

`scripts/signing.sh` — certyfikat „Bifold Self-Signed” w `~/Library/Keychains/bifold-signing.keychain-db`
(tworzony przy pierwszym `make installer`). Stały podpis = macOS nie zapomina Pełnego dostępu do dysku
ani zgód Pęku kluczy po aktualizacji.

**Kopia zapasowa** (bez niej nowa tożsamość na innym Macu oznacza jednorazowe ponowne nadanie zgód):
```sh
scripts/signing.sh export ~/Bezpieczne    # pęk kluczy podpisu + jego hasło — poza repozytorium!
scripts/signing.sh restore ~/Bezpieczne   # na nowym Macu
```

Developer ID (opcjonalnie, płatne): po ustawieniu podpisu Developer ID i notaryzacji Gatekeeper
przestanie ostrzegać, a pomocnik administratora (SMAppService) zacznie działać.

## Klucz aktualizacji (EdDSA)

Prywatny w Pęku kluczy logowania (konto `bifold`), publiczny w `Config/Brand.xcconfig`
(`BIFOLD_SPARKLE_PUBLIC_KEY`).
```sh
scripts/sparkle-tools.sh generate_keys -p              # klucz publiczny
scripts/sparkle-tools.sh generate_keys -x ~/Bezpieczne/bifold-sparkle-eddsa-private.txt   # kopia — poza repozytorium!
scripts/sparkle-tools.sh generate_keys -f ~/Bezpieczne/bifold-sparkle-eddsa-private.txt   # odtworzenie na nowym Macu
```
Utrata klucza prywatnego = zainstalowane kopie nie przyjmą kolejnych aktualizacji (jednorazowa ręczna
instalacja wersji z nowym kluczem).

## Wydanie

Repozytorium musi być publiczne — aplikacja pobiera kanał
`https://github.com/andrzejoles/Bifold/releases/latest/download/appcast.xml` bez logowania.

```sh
git checkout main && git pull
scripts/release.sh                       # instalatory, ZIP dla Sparkle, appcast.xml, tag, SZKIC wydania
gh release edit vX.Y.Z --draft=false     # publikacja po sprawdzeniu szkicu
```

Zainstalowane kopie sprawdzają kanał raz dziennie, pobierają aktualizację w tle i instalują ją przy
zamknięciu aplikacji (menu „Sprawdź uaktualnienia…” — od razu).

## Próba aktualizacji lokalnie

```sh
make installer
# „stara” kopia: ditto dist/Bifold-X.app /tmp/test/Bifold.app, w Info.plist niższe
# CFBundleVersion i CFBundleShortVersionString, scripts/signing.sh sign /tmp/test/Bifold.app
# kanał: ZIP nowej wersji (ditto -c -k --keepParent) w katalogu kanal/ i
scripts/sparkle-tools.sh generate_appcast --download-url-prefix http://127.0.0.1:8000/ kanal/
(cd kanal && python3 -m http.server 8000 --bind 127.0.0.1) &
open -n --env BIFOLD_UPDATE_FEED=http://127.0.0.1:8000/appcast.xml --env BIFOLD_UPDATE_CHECK_NOW=1 /tmp/test/Bifold.app
# po pobraniu zamknij aplikację — Sparkle podmieni pakiet
```
Sprawdzone 2026-10-17: 1.0.14 → 1.0.15, podpis i wymaganie podpisu bez zmian.

## Pierwsza instalacja na innym Macu

Aplikacja nie jest notaryzowana: Ustawienia systemowe → Prywatność i ochrona → „Otwórz mimo to”
(albo `xattr -dr com.apple.quarantine /Applications/Bifold.app`). Aktualizacje instalowane przez
Sparkle nie przechodzą ponownie przez kwarantannę.
