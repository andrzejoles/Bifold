# Bifold — wskazówki dla sesji Claude Code

Dwupanelowy menedżer plików dla macOS 27 (Swift 6, AppKit). Wymagania: `docs/PROMPT.md`,
architektura: `docs/ARCHITECTURE.md`, bezpieczeństwo: `docs/SECURITY.md`, decyzje: `docs/DECISIONS.md`.

## Zasady (decyzje właściciela)

- **Wersja** z historii gita jak w CantatePresenter (`scripts/version.sh`, `docs/WYDANIA.md`). Nie wpisuj
  numeru wersji ręcznie. Zmiany na `main` przez PR scalane zwykłym „Merge pull request” (nie squash).
- **Autor** wszędzie jako „Andrzej Oleś w kooperacji z Claude AI” (`BIFOLD_COPYRIGHT` w `Config/Brand.xcconfig`).
- Nazwa i bundle id tylko w `Config/Brand.xcconfig`.
- Każda czynność jest komendą w rejestrze (klawiatura, menu, paleta i agent korzystają z tych samych komend),
  z poziomem dostępu agenta i opisem skutków.
- Sekrety tylko w Pęku kluczy; nigdy w plikach, argumentach procesów, zmiennych środowiskowych ani logach
  (jedyny wyjątek: krótkotrwały token sesji agenta w środowisku procesu CLI — `docs/SECURITY.md` A5).
  Repozytorium jest publiczne — przed commitem nic z `~/Library`, `~/.ssh`, kluczy, haseł, ścieżek domowych.
- Testy nie dotykają `~/.ssh` ani prawdziwych danych aplikacji (`Workspace(persists: false)`).
- **Teksty interfejsu** tylko przez `L10n.tr("…")` (kluczem jest polskie zdanie). Każdy nowy tekst: `make build`,
  `python3 scripts/gen-strings.py` (klucze z kompilatora), potem tłumaczenia en, de, es, uk w
  `App/Resources/Localizable.xcstrings` — pilnuje tego `LocalizationCatalogTests` (także znaczników `%@`/`%lld`).

## Polecenia

```sh
make bootstrap && make build      # pierwsze budowanie
make test                         # testy BifoldKit (w tym SCP z lokalnym sshd, SFTP z rclone serve)
make installer                    # dist/Bifold-X.Y.Z.dmg i .pkg
scripts/release.sh                # szkic wydania na GitHubie (tylko z main)
python3 scripts/gen-strings.py    # katalog tłumaczeń po dodaniu tekstów L10n.tr (po make build)
make unregister                   # usuwa z Launchpada kopie Bifolda spoza /Applications
```

## Pułapki

- `Foundation.Process` przekazuje argumenty jako NFD — wzorce przez pliki (`rg --file`, `7zz @lista`),
  SSH/SCP przez `Spawn` (posix_spawn).
- Nowy plik źródłowy w `App/` wymaga `xcodegen generate` (`make generate`).
- Narzędzia Sparkle przez `scripts/sparkle-tools.sh` (inaczej okno zgody Pęku kluczy).
