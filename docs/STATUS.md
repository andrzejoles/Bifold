# Stan realizacji (2026-10-17)

Wszystkie siedem etapów z [PROMPT.md](PROMPT.md) jest zaimplementowanych. Testy: **168** (wszystkie zielone) w
pakiecie `BifoldKit` (`make test`) + test wydajności w Release (`make test-release`) + opcjonalny test
E2E z prawdziwymi CLI agentów. Zgodnie z poleceniem „w pełni autonomicznie” punkty „pokaż i poczekaj
na akceptację” zastąpiłem wpisami w [DECISIONS.md](DECISIONS.md).

Legenda: ✅ zweryfikowane testem automatycznym · 👁 sprawdzone ręcznie w działającej aplikacji
(zrzuty ekranu) · ⚠️ zaimplementowane, bez weryfikacji na żywo (powód w kolumnie).

## Etap 1 — rdzeń lokalny

| Kryterium | Stan |
|---|---|
| Codzienna praca tylko z klawiatury (F-klawisze, Tab, Spacja, szybkie wyszukiwanie, paleta) | ✅ komendy + 👁 strzałki, Spacja, wpisywanie, Tab, F3, Ctrl+1…4, Cmd+L |
| Katalog ze 100 000 plików < 1 s | ✅ Release: **0,23 s** (listowanie 0,09 s, sortowanie 0,08 s) |
| Operacje w tle: pauza, wznowienie, limit, anulowanie bez częściowego pliku | ✅ (także wewnątrz `copyfile`) |
| Cofanie przeniesienia, zmiany nazwy, Kosza (z wykrywaniem konfliktów) | ✅ |
| Wszystkie czynności w rejestrze komend; menu z rejestru | ✅ (`docs/SKROTY.md` generowane z rejestru) |
| Widoki: szczegóły, lista skrócona, miniatury, kolumny; drzewo; podgląd F3 (tekst/hex/obraz) | 👁 |
| Terminal SwiftTerm, linia poleceń | 👁 |

## Etap 2 — API agentów

| Kryterium | Stan |
|---|---|
| Każdy z 4 agentów uruchomiony z aplikacji czyta zaznaczenie i nawiguje | ✅ E2E: Claude Code, Codex, Grok, Antigravity (`AgentE2ETests`) + 👁 Claude i Codex w panelu agenta |
| Połączenie bez tokenu / z błędnym tokenem / spoza drzewa procesów odrzucane | ✅ |
| Narzędzia z poziomem „Brak” niewidoczne | ✅ |
| Zablokowane ścieżki niedostępne (też przez `..` i dowiązania) | ✅ |
| Cofnięcie sesji agenta przywraca stan sprzed sesji | ✅ |
| Okno zatwierdzania z podglądem | ✅ logika + 👁 (poprawione po teście: brak przycisku domyślnego, D23) |

## Etapy 3–7

| Funkcja | Stan |
|---|---|
| Wyszukiwanie: nazwa, regex, treść (ripgrep, windows-1250), filtry, zapisane, wyniki w panelu | ✅ |
| Spotlight | ⚠️ zależy od indeksu Spotlight — kod bez testu automatycznego |
| Duplikaty, sumy MD5/SHA-1/SHA-256, dzielenie/łączenie | ✅ |
| Zmiana nazw wielu plików (maski, licznik, EXIF, multimedia, regex, wielkość liter, cofanie zamian) | ✅ (EXIF na wygenerowanym JPEG; tagi multimediów bez testu) |
| Archiwa: ZIP/7z/TAR/TAR.GZ/BZ2/XZ, polskie nazwy, hasła, wieloczęściowe, archiwum jak katalog, szukanie w archiwach | ✅ (RAR — rozpakowywanie przez 7zz, bez pliku testowego) |
| Serwery: SFTP, FTP, WebDAV przez rclone (gniazdo Unix, konfiguracja w pamięci), przesyłanie, cofanie pobrań | ✅ z lokalnymi serwerami `rclone serve` |
| SCP (`scp -O`) na serwerze bez SFTP, tylko ze starymi algorytmami (jak AIX 6.1); SFTP w trybie zgodności | ✅ z lokalnym `sshd` (bez roota, bez SFTP, tylko `diffie-hellman-group14-sha1`, `ssh-rsa`, `aes128-cbc`) |
| Terminal SSH w drugim panelu (logowanie bez hasła, katalog z panelu, klawisze, rozłączenie) | ✅ test + 👁 na żywo z lokalnym `sshd` (Tab, F5, Ctrl+Tab, rozłączenie) |
| Odrzucenie podstawionego serwera (zmieniony klucz) dla SFTP i SCP | ✅ |
| Nazwy w ISO-8859-2 na serwerze SCP | ⚠️ kodowanie i parser testowane; brak serwera z takimi nazwami (APFS ich nie przechowa) |
| Automatyczna aktualizacja (Sparkle) | ✅ ręcznie: kopia 1.0.14 pobrała z lokalnego kanału 1.0.15, sprawdziła podpis EdDSA i podmieniła się przy zamknięciu, ten sam podpis |
| Interfejs w 5 językach, eksport/import tłumaczeń | ✅ testy (import, odrzucanie złych znaczników, kompletność katalogu) + 👁 interfejs po angielsku; tłumaczenia maszynowe do przejrzenia |
| Instalatory DMG i PKG | ✅ zbudowane i sprawdzone (zawartość, podpis); bez notaryzacji |
| Zasada najmniejszego poziomu: SFTP tylko odczyt, FTP za zgodą, FTP→SFTP zabronione | ✅ |
| SMB/NFS (NetFS), Google Drive / Dropbox / OneDrive (OAuth) | ⚠️ brak serwera SMB i kont chmurowych w środowisku testowym |
| Edycja plików zdalnych (wysyłka po zapisie) | ⚠️ bez testu automatycznego |
| Porównanie plików (tekst/binarne), katalogów, synchronizacja 3 tryby z podglądem i Koszem | ✅ |
| Android (MTP) | ✅ protokół na fałszywym pomocniku + na żywo Samsung SM-F776B: nośnik, folder główny 0,14 s, DCIM 0,09 s, DCIM/Camera (1507 zdjęć) 34 s, pobranie pliku |
| iPhone (AFC) | ⚠️ parser przetestowany na przykładowych wyjściach; brak iPhone’a do testu na żywo |
| Pomocnik administratora (SMAppService + XPC + autoryzacja) | ⚠️ logika i walidacja testowane; rejestracja demona wymaga podpisu z zespołem (D36) |

## Znane ograniczenia

- **Android:** foldery z tysiącami plików (np. DCIM/Camera) wczytują się kilkadziesiąt sekund — libmtp pyta
  telefon o każdy plik osobno. Telefon obsługuje jedną sesję MTP naraz (zamknij inne programy).

- **Gatekeeper**: aplikacja ma stały podpis z własnym certyfikatem, ale nie jest notaryzowana — na innym
  Macu pierwsze uruchomienie wymaga „Otwórz mimo to” (Developer ID kosztuje 99 USD rocznie).
- **SCP**: bez przenoszenia (F6), synchronizacji i wyszukiwania na serwerze; DSA nieobsługiwane.

- **Pomocnik administratora** nie zarejestruje się przy podpisie „Sign to Run Locally” — ustaw
  `DEVELOPMENT_TEAM` w `Config/Brand.xcconfig` (darmowy zespół osobisty wystarczy) i wymaganie podpisu.
- **Antigravity** nie ma serwera MCP na sesję — przy pierwszym uruchomieniu Bifold pyta o zgodę
  na trwałe `agy mcp add bifold …` (bez tokenu most odrzuca połączenia).
- **Grok** startuje w trybie bez interfejsu wolno (~4 min w teście E2E) — to czas samego CLI.
- **Operacje na serwerach** (wysyłka, zmiana nazwy, usunięcie) nie są cofalne — serwery nie mają Kosza (D32).
- **Wyszukiwanie w archiwach** dotyczy nazw, nie treści.
- Tłumaczenia en, de, es, uk przygotował Claude — warto, żeby przejrzały je osoby znające te języki
  (eksport w danym języku → poprawki → import).
