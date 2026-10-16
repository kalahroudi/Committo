#!/usr/bin/env python3
"""Renders docs/screenshots/*.png from the public demo (docs/demo/index.html).
Needs Chrome or Chromium (set CHROME to override) and Pillow (pip install pillow)."""
import os, pathlib, re, shutil, subprocess, sys, tempfile
from PIL import Image, ImageChops

root = pathlib.Path(__file__).resolve().parent.parent
cands = [os.environ.get("CHROME", ""), "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
         "/Applications/Chromium.app/Contents/MacOS/Chromium", shutil.which("google-chrome") or "", shutil.which("chromium") or "",
         *map(str, sorted(pathlib.Path("/opt/pw-browsers").glob("chromium-*/chrome-linux/chrome")))]
chrome = next((c for c in cands if c and os.path.exists(c)), None)
if not chrome: sys.exit("Chrome/Chromium not found; set CHROME")

html = (root / "docs/demo/index.html").read_text(encoding="utf-8")
ids = re.findall(r'\["(\w+)","[^"]+"\]', re.search(r"SCREENS=\[.*?\];", html, re.S).group(0))
tweak = "header.top,nav.tabs,.shead,.notes,footer.sum{display:none!important}.cols{display:block}body{padding:18px!important}.stage{padding:18px}"
tmp = pathlib.Path(tempfile.mkdtemp()) / "shot.html"
tmp.write_text(html.replace("</style>", tweak + "</style>"), encoding="utf-8")
out = root / "docs/screenshots"; out.mkdir(exist_ok=True)
keep = set()
for i in ids:
    f = out / f"{i}.png"; keep.add(f.name)
    subprocess.run([chrome, "--headless", "--no-sandbox", "--hide-scrollbars", "--window-size=1100,1050", f"--screenshot={f}", f"file://{tmp}#{i}"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
    im = Image.open(f).convert("RGB"); box = ImageChops.difference(im, Image.new("RGB", im.size, im.getpixel((0, 0)))).getbbox()
    if not box: sys.exit(f"blank screenshot for {i}")
    l, t, r, b = box; im.crop((max(l-12, 0), max(t-12, 0), min(r+12, im.width), min(b+12, im.height))).save(f, optimize=True)
for stale in out.glob("*.png"):
    if stale.name not in keep: stale.unlink(); print("removed", stale.name)
print("wrote", len(ids), "screenshots")
