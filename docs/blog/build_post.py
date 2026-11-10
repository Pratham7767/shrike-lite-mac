#!/usr/bin/env python3
"""Build the blog post from post_template.md.

Outputs (next to this script):
  post_dev.md          Markdown for DEV / Hashnode. Images are links to this repo on
                       GitHub, so the site shows them automatically after you push.
  post_standalone.html One self-contained HTML file with every image embedded
                       (open it in a browser to preview, or share it as a single file).

Usage:
  python build_post.py YOUR_GITHUB_USERNAME [repo-name] [branch]
  (defaults: repo-name = shrike-lite-mac, branch = main)

Needs: Python 3 and `pip install markdown` (only for the HTML file).
"""
import base64
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
IMG_DIR = os.path.join(HERE, "..", "images")
TITLE = "Building a Signed Multiply-Accumulate (MAC) Unit on the Shrike Lite FPGA: A Beginner's Guide"
IMG_RE = re.compile(r"\{\{IMG:([^|}]+)\|([^}]*)\}\}")


def main():
    user = sys.argv[1] if len(sys.argv) > 1 else "YOUR_GITHUB_USERNAME"
    repo = sys.argv[2] if len(sys.argv) > 2 else "shrike-lite-mac"
    branch = sys.argv[3] if len(sys.argv) > 3 else "main"
    repo_url = "https://github.com/%s/%s" % (user, repo)
    raw = "https://raw.githubusercontent.com/%s/%s/%s/docs/images/" % (user, repo, branch)

    with open(os.path.join(HERE, "post_template.md"), encoding="utf-8") as f:
        text = f.read()
    text = text.replace("{{REPO_LINK}}", "[%s](%s)" % (repo_url, repo_url))

    # 1) Markdown for DEV / Hashnode: images by URL + italic caption
    md = IMG_RE.sub(lambda m: "![%s](%s%s)\n*%s*" % (m.group(2), raw, m.group(1), m.group(2)), text)
    with open(os.path.join(HERE, "post_dev.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write(md)

    # 2) Self-contained HTML: images embedded as base64
    try:
        import markdown
    except ImportError:
        print("post_dev.md written. For the HTML file run: pip install markdown")
        return

    def embed(m):
        with open(os.path.join(IMG_DIR, m.group(1)), "rb") as img:
            data = base64.b64encode(img.read()).decode("ascii")
        return ('<figure><img src="data:image/png;base64,%s" alt="%s">'
                '<figcaption>%s</figcaption></figure>' % (data, m.group(2), m.group(2)))

    body = markdown.markdown(IMG_RE.sub(lambda m: "\n\n@@FIG%s@@\n\n" % m.start(), text),
                             extensions=["tables", "fenced_code"])
    for m in IMG_RE.finditer(text):
        body = body.replace("<p>@@FIG%s@@</p>" % m.start(), embed(m))

    css = """
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:760px;margin:40px auto;
padding:0 16px;line-height:1.6;color:#1f2328;background:#fff}
h1{font-size:2rem;line-height:1.25}h2{margin-top:2.2rem;border-bottom:1px solid #d0d7de;padding-bottom:.3rem}
table{border-collapse:collapse;width:100%;margin:1rem 0;font-size:.95rem;display:block;overflow-x:auto}
th,td{border:1px solid #d0d7de;padding:6px 10px;text-align:left;vertical-align:top}th{background:#f6f8fa}
code{background:#f6f8fa;padding:.1em .35em;border-radius:4px;font-size:.92em}
pre{background:#f6f8fa;padding:12px 14px;border-radius:8px;overflow-x:auto}pre code{background:none;padding:0}
figure{margin:1.5rem 0;text-align:center}figure img{max-width:100%;border:1px solid #d0d7de;border-radius:6px}
figcaption{font-size:.9rem;color:#57606a;font-style:italic;margin-top:.4rem}
@media (prefers-color-scheme:dark){body{background:#0d1117;color:#e6edf3}th{background:#161b22}
code,pre{background:#161b22}th,td,h2,figure img{border-color:#30363d}figcaption{color:#8b949e}}
"""
    html = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>%s</title><style>%s</style></head><body><h1>%s</h1>%s</body></html>'
            % (TITLE, css, TITLE, body))
    with open(os.path.join(HERE, "post_standalone.html"), "w", encoding="utf-8") as f:
        f.write(html)
    print("Wrote post_dev.md and post_standalone.html (images from %s)" % raw)


if __name__ == "__main__":
    main()
