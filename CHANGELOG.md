# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/).

## [Unreleased]

### Dodane — Etap 1 (rdzeń lokalny)
- Dokumentacja startowa: architektura, model zagrożeń, plan Etapu 1, decyzje, biblioteki.
- `BifoldCore`: `FileSystemProvider`, `LocalFS` (getattrlistbulk, FSEvents), kopiowanie i przenoszenie
  przez `copyfile(3)` z pauzą, limitem prędkości, anulowaniem i konfliktami, kolejka zadań, dziennik
  operacji (JSONL) z cofaniem i wykrywaniem konfliktów, maski TC, reguły kolorów (JSON), kodowania.
- `BifoldWorkspace`: model stanu (panele, karty, zaznaczenie, filtr), rejestr ~80 komend z poziomami
  agenta i podglądem skutków, profile skrótów TC i Cmd, zapis sesji.
- Aplikacja: dwa panele z kartami, widoki szczegóły/lista skrócona/miniatury/kolumny, drzewo, szybkie
  wyszukiwanie i filtr, pasek stanu, podgląd F3 (tekst/hex HexFiend/obraz), Quick Look, panel podglądu,
  edytor F4 (Nextpad++), linia poleceń i terminal SwiftTerm, kolejka operacji, paleta komend,
  ustawienia, dziennik operacji, woluminy, tagi, atrybuty, Udostępnij, Otwórz za pomocą.
