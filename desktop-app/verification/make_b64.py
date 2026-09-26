# -*- coding: utf-8 -*-
import base64, io
from PIL import Image

SRC = r"C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\shots\avatar-girl-portrait.png"
OUT = r"C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\verification\_avatar_b64.txt"

img = Image.open(SRC).convert("RGBA")
img = img.resize((128, 128), Image.NEAREST)  # keep pixel-art crispness
buf = io.BytesIO()
img.save(buf, "PNG", optimize=True)
b64 = base64.b64encode(buf.getvalue()).decode("ascii")
with open(OUT, "w", encoding="ascii") as f:
    f.write(b64)
print("png bytes:", len(buf.getvalue()), "b64 len:", len(b64))
