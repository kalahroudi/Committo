#!/usr/bin/env python3
"""Builds docs/demo/index.html: the mockup as a standalone page for GitHub Pages.

docs/mockup/index.html is the source (a fragment, as the Artifact publisher expects). This wraps it in a full
document (doctype, charset, viewport, reset) and adds social-preview tags. Run after editing the mockup:
    python3 Scripts/build-pages.py
"""
import pathlib, re

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "docs/mockup/index.html").read_text(encoding="utf-8")
SITE = "https://kalahroudi.github.io/Committo"

i = src.index("</style>") + len("</style>")
head, body = src[:i], src[i:]
head = re.sub(r'<meta name="claude:viewport-fit-sides"[^>]*>\n?', "", head)

pre = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="description" content="Interactive mockup of Committo, a native Mac git client for people who build with AI agents.">
<meta property="og:title" content="Committo mockup">
<meta property="og:description" content="21 clickable screens: menu-bar popover, merge preview, CI live board, SecurityCage, Tailscale runners and more.">
<meta property="og:image" content="{SITE}/screenshots/popover.png">
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary_large_image">
<style>:root{{color-scheme:light}}body{{margin:0;font:14px system-ui,-apple-system,sans-serif}}img{{max-width:100%}}[hidden]{{display:none!important}}</style>
"""
(root / "docs/demo").mkdir(exist_ok=True)
(root / "docs/demo/index.html").write_text(pre + head + "\n</head>\n<body>\n" + body + "\n</body>\n</html>\n", encoding="utf-8")
print("wrote docs/demo/index.html")
