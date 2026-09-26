# -*- coding: utf-8 -*-
"""Extract platform-agnostic assets from ScheduleWidget.ps1:
   - design/tokens.json : light/night palettes (design tokens)
   - design/lang.json   : zh/en language tables (UI strings)
These are the reusable assets for the future PWA/MAUI rewrite."""
import json, re, io

ROOT = r"C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app"
src = open(ROOT + r"\ScheduleWidget.ps1", encoding="utf-8-sig").read()

def block(name):
    m = re.search(r"(?s)\$script:" + name + r" = \[ordered\]@\{(.*?)\n\}", src)
    assert m, name + " block not found"
    return m.group(1)

def pairs(text, val_pattern, keyed=True):
    if keyed:
        pat = r"'([^'\s]+)'\s*=\s*" + val_pattern
    else:
        pat = r"([A-Za-z]+)\s*=\s*" + val_pattern   # palette keys are unquoted
    out = {}
    for k, v in re.findall(pat, text):
        out[k] = v
    return out

palette = {}
for theme in ("PaletteLight", "PaletteNight"):
    palette[theme.replace("Palette", "").lower()] = pairs(
        block(theme), r"'(#[0-9A-Fa-f]{6})'", keyed=False)

lang = {}
for code in ("LangEn", "LangZh"):
    lang[code.replace("Lang", "").lower()] = pairs(block(code), r"'([^']*)'")

# Parity checks (same standard as the audit)
assert set(palette["light"]) == set(palette["night"]), "palette key mismatch"
assert set(lang["en"]) == set(lang["zh"]), "lang key mismatch"

import os
os.makedirs(ROOT + r"\design", exist_ok=True)
meta = {
    "app": "MyScheduleWidget",
    "author": "蒲桃",
    "note": "Design tokens extracted from the WPF source. Single source of truth for the future cross-platform rewrite. Do not hand-edit values here without updating ScheduleWidget.ps1.",
}
tokens = dict(meta)
tokens.update({"color": palette, "fontFamily": "Microsoft YaHei", "fontFamilyMono": "Consolas",
               "fontScale": {"userSteps": [0.85, 1.0, 1.15, 1.3], "adaptive": {"<900px": 0.90, ">=1280px": 1.08}},
               "radii": {"card": 8, "pill": 8, "widget": 12, "btn": 7}})
with io.open(ROOT + r"\design\tokens.json", "w", encoding="utf-8") as f:
    json.dump(tokens, f, ensure_ascii=False, indent=2)
langdoc = {"app": "MyScheduleWidget", "note": "UI strings. {0}-style placeholders follow .NET format strings.",
           "default": "zh", "strings": lang}
with io.open(ROOT + r"\design\lang.json", "w", encoding="utf-8") as f:
    json.dump(langdoc, f, ensure_ascii=False, indent=2)
print("palette keys:", len(palette["light"]), "| lang keys:", len(lang["zh"]))
print("written: design/tokens.json, design/lang.json")
