# -*- coding: utf-8 -*-
"""Build a single-file script (dist-build/MySchedule-single.ps1) by inlining
   the 4 part files into ScheduleWidget.ps1, plus a multi-size app.ico."""
import re, os
from PIL import Image

ROOT = r"C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app"
OUT_DIR = ROOT + r"\dist-build"
os.makedirs(OUT_DIR, exist_ok=True)

main = open(ROOT + r"\ScheduleWidget.ps1", encoding="utf-8-sig").read()

# --- locate the part-loading foreach block and replace it with inlined parts ---
start_marker = "foreach ($part in @('Ui.ps1', 'Views.ps1', 'Views2.ps1', 'Care.ps1')) {"
i = main.index(start_marker)
# block ends at the first column-0 closing brace after the marker
j = main.index("\n}", i) + 2
original_block = main[i:j]
assert "Write-Trace ('part loaded: ' + $part)" in original_block

parts = ""
for name in ("Ui.ps1", "Views.ps1", "Views2.ps1", "Care.ps1"):
    body = open(ROOT + "\\" + name, encoding="utf-8-sig").read()
    parts += "\n# ==== part: " + name + " (inlined by Build-Single) ====\n" + body + "\n"

replacement = (
    "# ==== 单文件构建版：4 个分片已内联（由 verification/build_single.py 生成）。====\n"
    "# 内联与点源同落在脚本作用域，语义等价；发布后不需要旁边再有那 4 个文件。\n"
    "# 审计区读外部 Care.ps1 源码的那条断言在单文件版里会走它自己的 catch，无碍。\n"
    + parts
)
merged = main[:i] + replacement + main[j:]

# sanity: no leftover dot-source of parts, marker gone
assert start_marker not in merged
out = OUT_DIR + r"\MySchedule-single.ps1"
open(out, "w", encoding="utf-8-sig", newline="").write(merged)
print("merged:", out, len(merged), "chars")

# --- app.ico from the girl portrait (multi-size) ---
src = Image.open(ROOT + r"\shots\avatar-girl-portrait.png").convert("RGBA")
src.save(OUT_DIR + r"\app.ico", sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
print("icon:", OUT_DIR + r"\app.ico")
