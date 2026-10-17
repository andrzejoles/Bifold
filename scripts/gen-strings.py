#!/usr/bin/env python3
"""Zbiera teksty interfejsu (L10n.tr("…") i String(localized: "…")) z całego kodu
i uzupełnia App/Resources/Localizable.xcstrings (język źródłowy: polski).

Interpolacje Swift \\(…) zamieniane są na %@ / %lld — tak jak klucze generowane przez
String.LocalizationValue. Istniejące tłumaczenia są zachowywane; klucze, których już nie ma
w kodzie, są oznaczane jako "stale".
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "App/Resources/Localizable.xcstrings")
PATTERN = re.compile(r'(?:L10n\.tr|String\(localized:)\s*\(?\s*"((?:[^"\\]|\\.|\\\((?:[^()]|\([^()]*\))*\))*)"')
NUMERIC_HINT = re.compile(r'count|Count|\.size|performed|n\b|Int|limit|amount|\bi\b|index', re.S)

def to_key(literal: str) -> str:
    out, i = "", 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(literal) and depth:
                depth += {"(": 1, ")": -1}.get(literal[j], 0)
                j += 1
            expr = literal[i + 2:j - 1]
            out += "%lld" if re.fullmatch(r'[\w.]*(count|Count|performed|fontSize\)|callsPerMinute)[\w.]*|Int\(.*\)|n|i|mb', expr) else "%@"
            i = j
        elif literal.startswith("\\n", i):
            out += "\n"; i += 2
        elif literal.startswith('\\"', i):
            out += '"'; i += 2
        else:
            out += literal[i]; i += 1
    return out

keys = set()
for base in ("App/Sources", "Packages/BifoldKit/Sources"):
    for dirpath, _, files in os.walk(os.path.join(ROOT, base)):
        for f in files:
            if f.endswith(".swift"):
                text = open(os.path.join(dirpath, f), encoding="utf-8").read()
                for m in PATTERN.finditer(text):
                    keys.add(to_key(m.group(1)))
        # wielowierszowe literały """ … """ w L10n.tr pomijamy — mają klucz równy treści

catalog = {"sourceLanguage": "pl", "strings": {}, "version": "1.0"}
if os.path.exists(CATALOG):
    catalog = json.load(open(CATALOG, encoding="utf-8"))
strings = catalog.setdefault("strings", {})
added = 0
for k in sorted(keys):
    if k not in strings:
        strings[k] = {"extractionState": "manual"}
        added += 1
    elif strings[k].get("extractionState") == "stale":
        strings[k]["extractionState"] = "manual"
for k, v in strings.items():
    if k not in keys and v.get("extractionState") == "manual":
        v["extractionState"] = "stale"
catalog["strings"] = dict(sorted(strings.items()))
with open(CATALOG, "w", encoding="utf-8") as fh:
    json.dump(catalog, fh, ensure_ascii=False, indent=2, sort_keys=False)
    fh.write("\n")
print(f"{len(keys)} kluczy, dodano {added} → {os.path.relpath(CATALOG, ROOT)}")
