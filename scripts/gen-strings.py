#!/usr/bin/env python3
"""Uzupełnia App/Resources/Localizable.xcstrings (język źródłowy: polski) kluczami z kodu.

Klucze bierzemy z plików .stringsdata, które kompilator Swift zapisuje przy budowaniu
(SWIFT_EMIT_LOC_STRINGS) — mają dokładne znaczniki wartości (%@ dla tekstu, %lld dla liczby…),
takie same jak klucz, którego szuka `String(localized:)` w działaniu. Dlatego najpierw `make build`.
Istniejące tłumaczenia są zachowywane; klucze, których nie ma już w kodzie, są usuwane.
Brakujące tłumaczenia (en, de, es, uk) wykrywa test LocalizationCatalogTests.
"""
import glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "App/Resources/Localizable.xcstrings")
INTERMEDIATES = os.path.join(ROOT, "build/DerivedData.noindex/Build/Intermediates.noindex")
OWN_TARGETS = ("Bifold.build/Debug/Bifold.build", "BifoldKit.build/Debug/Bifold")

files = [f for f in glob.glob(os.path.join(INTERMEDIATES, "**/*.stringsdata"), recursive=True)
         if any(t in f for t in OWN_TARGETS)]
if not files:
    sys.exit("Brak plików .stringsdata — najpierw zbuduj aplikację (make build).")

keys = set()
for f in files:
    data = json.load(open(f, encoding="utf-8"))
    source = data.get("source", "")
    # Tylko nasze źródła (bez zależności i plików pośrednich).
    if not (source.startswith(os.path.join(ROOT, "App/Sources")) or source.startswith(os.path.join(ROOT, "Packages/BifoldKit/Sources"))):
        continue
    if not os.path.exists(source):
        continue
    for entry in data.get("tables", {}).get("Localizable", []):
        keys.add(entry["key"])

catalog = {"sourceLanguage": "pl", "strings": {}, "version": "1.0"}
if os.path.exists(CATALOG):
    catalog = json.load(open(CATALOG, encoding="utf-8"))
strings = catalog.setdefault("strings", {})
added = 0
for k in sorted(keys):
    if k not in strings:
        strings[k] = {"extractionState": "manual"}
        added += 1
    else:
        strings[k]["extractionState"] = "manual"
# Napisy techniczne (przykłady w polach formularzy, porty, polecenia, same znaczniki) — bez tłumaczenia.
TECHNICAL = {"/var/log", "21", "22", "445", "ctrl+shift+k", "https://dav.example.com/remote.php/dav", "login",
             "prod-logi", "serwer.example.com", "~/.ssh/id_ed25519", "brew install %@"}
for k in keys:
    words = re.sub(r"%(\d+\$)?(ll|l)?[@dfs%]", "", k)
    if k in TECHNICAL or not re.search(r"[A-Za-zĄĆĘŁŃÓŚŹŻąćęłńóśźż]{2}", words):
        strings[k]["shouldTranslate"] = False
    else:
        strings[k].pop("shouldTranslate", None)
removed = [k for k in strings if k not in keys]
for k in removed:
    del strings[k]
catalog["strings"] = dict(sorted(strings.items()))
with open(CATALOG, "w", encoding="utf-8") as fh:
    json.dump(catalog, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print(f"{len(keys)} kluczy, dodano {added}, usunięto {len(removed)} → {os.path.relpath(CATALOG, ROOT)}")
