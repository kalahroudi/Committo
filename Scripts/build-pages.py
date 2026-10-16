#!/usr/bin/env python3
"""Builds docs/demo/index.html, the public mockup for GitHub Pages.

design/mockup/index.html is the full working copy (a fragment, as the Artifact publisher expects). The public build:
  - wraps it in a complete document with social-preview tags,
  - drops the logo-options screen and the review-only controls (Approve / Request changes),
  - replaces vendor-specific agent names with generic wording,
  - fails if any vendor name is left.
Run after editing the mockup, then `python3 Scripts/build-shots.py` to refresh the screenshots.
"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "design/mockup/index.html").read_text(encoding="utf-8")
SITE = "https://kalahroudi.github.io/Committo"

# 1. drop the logo exploration screen
src = re.sub(r'\n?<!-- LOGO -->\s*<section class="screen" id="s-logo".*?</section>', "", src, flags=re.S)
src = src.replace(',["logo","Logo"]', "")
assert 'id="s-logo"' not in src and '"logo"' not in src

# 2. generic wording
pairs = [
    ("Install in Claude Code", "Install in your agent"),
    ("Claude Code", "Agent CLI"),
    ("Ask Claude instead", "Ask the agent instead"),
    ("Use Claude", "Use agent"),
    ("tell Claude the result.", "share your notes with the author."),
    ("Tell Claude what to change on each.", "Note what to change on each."),
    ("claude/", "agent/"), ("-claude-", "-agent-"), ("@claude", "@agent-bot"),
    ("Anthropic API", "Model API"), ("Anthropic", "provider"),
    ("Claude", "Agent"), ("claude", "agent"),
]
for a, b in pairs:
    src = src.replace(a, b)
if re.search(r"claude|anthropic", src, re.I):
    sys.exit("build failed: vendor name still present: " + re.search(r".{30}(claude|anthropic).{30}", src, re.I | re.S).group(0))

src = re.sub(r"Committo — mockup v\d+", "Committo", src)

# 3. public-only presentation: hide review controls
hide = "<style>.approve,footer.sum,header.top .pill{display:none!important}</style>"
src = src.replace("</style>", "</style>\n" + hide, 1)
n = len(re.findall(r'\["\w+","[^"]+"\]', re.search(r"SCREENS=\[.*?\];", src, re.S).group(0)))
src = re.sub(r'<p class="sub">.*?</p>', f'<p class="sub">{n} clickable screens. A static design preview: nothing here runs git.</p>', src, count=1, flags=re.S)

i = src.index("</style>\n" + hide) + len("</style>\n" + hide)
head, body = src[:i], src[i:]
head = re.sub(r'<meta name="claude:viewport-fit-sides"[^>]*>\n?', "", head)

pre = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="description" content="Interactive mockup of Committo, a native Mac git client for people who build with AI agents.">
<meta property="og:title" content="Committo mockup">
<meta property="og:description" content="Clickable design preview: menu-bar popover, merge preview, CI live board, rebase, releases and more.">
<meta property="og:image" content="{SITE}/screenshots/popover.png">
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary_large_image">
<style>:root{{color-scheme:light}}body{{margin:0;font:14px system-ui,-apple-system,sans-serif}}img{{max-width:100%}}[hidden]{{display:none!important}}</style>
"""
out = pre + head + "\n</head>\n<body>\n" + body + "\n</body>\n</html>\n"
(root / "docs/demo").mkdir(exist_ok=True)
(root / "docs/demo/index.html").write_text(out, encoding="utf-8")
print("wrote docs/demo/index.html")
