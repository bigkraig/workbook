"""Render documents written by ferrari_extract.py as plain HTML pages, to eyeball
the structure next to the PDF. Not the app's renderer: just enough to see
sections, steps, notes, tables and figures.

    python ferrari_preview.py OUT_DIR      # writes OUT_DIR/<code>.html
"""
import glob
import html
import json
import os
import sys

CSS = """
body{font:15px/1.45 -apple-system,Helvetica,sans-serif;max-width:860px;margin:24px auto;padding:0 16px;color:#1c1c1c;background:#faf8f3}
h1{font-size:22px} h1 small{color:#8a6a2a;font-weight:600;margin-right:10px}
h2{font-size:16px;margin:26px 0 8px;border-bottom:2px solid #1c1c1c;padding-bottom:4px}
h2 h2,section section>h2{font-size:14px;border-bottom:1px solid #bbb}
.step{display:grid;grid-template-columns:40px 300px 1fr;gap:12px;margin:12px 0;padding:10px;background:#fff;border:1px solid #ddd;border-radius:8px}
.step .n{font:800 24px ui-rounded,sans-serif;color:#c0862c}
.step img,figure img{max-width:100%;border-radius:4px} figure{margin:10px 0}
ul{margin:4px 0;padding-left:20px} p{margin:4px 0}
.w{border-left:5px solid #999;background:#eee;padding:6px 10px;margin:6px 0;border-radius:4px}
.w b.l{font-size:11px;letter-spacing:1px;display:block}
.w.c1{border-color:#f5c518;background:#fff6cf}.w.c2{border-color:#f58c1a;background:#ffe6cc}.w.c3{border-color:#d6001c;background:#ffd9de}
.w.important{border-color:#d6001c;background:#fff0f0}.w.environment{border-color:#2e8b3d;background:#e8f6ea}
table{border-collapse:collapse;margin:8px 0;background:#fff} td,th{border:1px solid #bbb;padding:4px 8px;vertical-align:top;font-size:13px}
th{background:#ece7da;text-align:left} caption{font-weight:700;text-align:left;padding:4px 0}
a.qv-tool{background:#ffe95e;padding:0 3px;border-radius:3px;text-decoration:none;color:#000}
a.qv-doc{color:#0a7d2c} dl{display:grid;grid-template-columns:auto 1fr;gap:2px 10px} dt{font-weight:700}
"""
LABEL = {"0Hinweis": ("NOTE", ""), "1Vorsicht": ("CAUTION", "c1"), "2Warnung": ("WARNING", "c2"), "3Gefahr": ("DANGER", "c3"),
         "important": ("IMPORTANT", "important"), "environment": ("ENVIRONMENT", "environment")}


def render(value, media) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "".join(render(v, media) for v in value)
    kind, inputs = value["type"], value["inputs"]
    if kind == "static":
        return f"<p>{inputs['html']}</p>" if inputs.get("para") else f"<span>{inputs['html']}</span>"
    if kind == "section":
        return f"<section><h2>{html.escape(inputs.get('title') or '')}</h2>{render(inputs['children'], media)}</section>"
    if kind == "list":
        return "<ul>" + "".join(f"<li>{render(item, media)}</li>" for item in inputs["items"]) + "</ul>"
    if kind == "warning":
        label, css = LABEL.get(inputs["category"], (inputs["category"], ""))
        return f'<div class="w {css}"><b class="l">{label}</b>{render(inputs["children"], media)}</div>'
    if kind == "image":
        legend = "".join(f"<dt>{a}</dt><dd>{render(b, media)}</dd>" for a, b in inputs.get("legend", []))
        return (f'<figure><img src="media/{inputs["key"]}{media.get(inputs["key"], "")}">'
                + (f"<dl>{legend}</dl>" if legend else "") + "</figure>")
    if kind == "plot":
        out = []
        for item in inputs:
            figure = [c for c in item["children"] if c["type"] == "image"]
            rest = [c for c in item["children"] if c["type"] != "image"]
            out.append(f'<div class="step"><div class="n">{item["position"]}</div><div>{render(figure, media)}</div>'
                       f'<div>{render(rest, media)}</div></div>')
        return "".join(out)
    if kind == "table":
        def row(cells, tag):
            parts = []
            for cell in cells:
                span = ""
                if isinstance(cell, list):
                    cell, columns, _ = cell
                    span = f' colspan="{columns}"'
                parts.append(f"<{tag}{span}>{render(cell, media)}</{tag}>")
            return "<tr>" + "".join(parts) + "</tr>"
        caption = f"<caption>{html.escape(inputs['title'])}</caption>" if inputs.get("title") else ""
        return ("<table>" + caption + "".join(row(r, "th") for r in inputs.get("header", []))
                + "".join(row(r, "td") for r in inputs.get("data", [])) + "</table>")
    if kind == "mixed":
        return render(inputs["children"], media)
    return f"<pre>{html.escape(json.dumps(value)[:200])}</pre>"


if __name__ == "__main__":
    out_dir = sys.argv[1]
    for path in glob.glob(os.path.join(out_dir, "*.json")):
        if path.endswith("report.json"):
            continue
        document = json.load(open(path))
        page = (f"<!doctype html><meta charset=utf-8><title>{html.escape(document['title'])}</title><style>{CSS}</style>"
                f"<h1><small>{html.escape(document['code'])}</small>{html.escape(document['title'])}</h1>"
                + render(document["content"], document.get("media", {})))
        with open(path[:-5] + ".html", "w") as handle:
            handle.write(page)
