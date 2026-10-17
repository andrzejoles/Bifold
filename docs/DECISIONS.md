# Decyzje projektowe

Format: data — decyzja — powód. Najnowsze na dole.

### D1 · 2026-10-17 — Praca autonomiczna zamiast czekania na akceptację
Użytkownik polecił wykonać `PROMPT.md` „w pełni autonomicznie”. Punkty „pokaż i poczekaj na
akceptację” oraz „zapytaj” zastępuję wpisami w tym pliku: każda decyzja, o którą miałem pytać,
jest tu opisana z uzasadnieniem, żeby dało się ją łatwo zmienić.

### D2 · 2026-10-17 — XcodeGen (`project.yml`) jako źródło projektu Xcode
Ręczna edycja `project.pbxproj` jest podatna na konflikty i błędy. `project.yml` jest czytelny,
a wygenerowany `Bifold.xcodeproj` jest commitowany, więc do zwykłego budowania w Xcode XcodeGen
nie jest potrzebny (tylko przy zmianie struktury celów).

### D3 · 2026-10-17 — Nazwa i bundle id w `Config/Brand.xcconfig`
`PRODUCT_NAME`, `PRODUCT_BUNDLE_IDENTIFIER` i nazwa katalogu w Application Support pochodzą z
jednego pliku; kod czyta je z `Info.plist` (`Brand.swift`).

### D4 · 2026-10-17 — Kosz przez `FileManager.trashItem(at:resultingItemURL:)`
PROMPT wskazuje `NSWorkspace.recycle`. `FileManager.trashItem` robi to samo (ten sam mechanizm
Findera, zwraca nową ścieżkę w Koszu), ale działa synchronicznie i bez AppKit, więc może żyć w
`BifoldCore` i być testowane bez interfejsu. Nowa ścieżka w Koszu trafia do dziennika.

### D5 · 2026-10-17 — Kopiowanie przez `copyfile(3)` z callbackiem postępu
`COPYFILE_ALL` zachowuje dane, xattr, ACL i daty; `COPYFILE_CLONE` daje natychmiastowe klony na
APFS. Callback `COPYFILE_STATE_STATUS_CB` służy do postępu, pauzy (blokada w callbacku), limitu
prędkości (uśpienie w callbacku) i anulowania (`COPYFILE_QUIT`). Kopiowanie do pliku tymczasowego
`.bifold-partial` i atomowe `rename` na końcu — po anulowaniu nie zostaje częściowy plik.

### D6 · 2026-10-17 — Obserwacja modelu w AppKit przez `withObservationTracking`
Model to `@Observable` (framework Observation). Widoki AppKit rejestrują się helperem
`observe { … }`, który ponawia śledzenie po każdej zmianie (na głównym aktorze). Bez Combine.

### D7 · 2026-10-17 — Teksty interfejsu: klucze = polskie zdania, katalog w aplikacji
Polski jest językiem źródłowym, więc klucze `String(localized:)` są polskimi tekstami. Moduły SPM
używają `L10n.tr("…")`, który szuka tłumaczenia w `Bundle.main` (katalog `Localizable.xcstrings`
celu aplikacji). Skrypt `scripts/gen-strings.py` zbiera klucze z całego kodu i dopisuje brakujące
do katalogu, żeby dodanie nowego języka było kompletne.

### D8 · 2026-10-17 — HexFiend jako submoduł budowany skryptem
HexFiend nie ma pakietu SPM. Submoduł `ThirdParty/HexFiend` (tag v2.18.1) budowany jest przez
`scripts/build-hexfiend.sh` (cel `HexFiend_Framework`, arm64, Release) do `ThirdParty/build/`,
skąd aplikacja go linkuje i osadza. Sprawdzone: buduje się na Xcode 27 bez błędów.

### D9 · 2026-10-17 — Wykrywanie Full Disk Access
Brak oficjalnego API. Próba otwarcia do odczytu `~/Library/Application Support/com.apple.TCC/TCC.db`
(chroniony przez TCC); `EPERM` → brak FDA. Okno z instrukcją i przyciskiem otwierającym
`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.

### D10 · 2026-10-17 — Klawiatura: własny `KeyRouter` zamiast tylko `keyEquivalent` menu
Skróty TC (F-klawisze, Tab, Spacja, litery w szybkim wyszukiwaniu) nie mieszczą się w modelu
`keyEquivalent`. `KeyRouter` dopasowuje `NSEvent` do `KeyChord` z aktywnego `Keymap` i wywołuje
komendę z rejestru; menu pokazuje te same skróty (jeśli da się je wyrazić jako `keyEquivalent`).
