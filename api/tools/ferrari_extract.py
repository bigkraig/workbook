"""Convert tagged Ferrari techdoc PDFs into the structured document format the
Porsche documents use (the `content` tree of typed nodes), and check the
result against the PDF mechanically.

    python ferrari_extract.py --year 2017 --model F151M SOURCE_DIR OUT_DIR

Writes, per PDF under SOURCE_DIR, OUT_DIR/<pdf name>.json (the content tree,
its search text, its figures and whether it passed the checks), the figures
under OUT_DIR/media/, and OUT_DIR/report.json. `workbook load-ferrari
--structured OUT_DIR` then loads every document that passed as a structured
document and leaves the rest as PDFs.

Nothing is paraphrased or generated: every piece of text comes from the PDF.
A document passes only if its text matches the PDF character for character,
every number matches what an independent reader (poppler's pdftotext) finds,
and nothing in it went unrecognised.
"""
from __future__ import annotations

import collections
import difflib
import html
import json
import os
import re
import struct
import subprocess
import sys
import uuid
import zlib

from ferrari_pdf_dom import Dom, Image, Node, Target, Text

# Small images the techdoc site uses as markers, by content hash.
ICONS = {
    "c6f22e9f6848": "step",      # arrowhead: a step outside a photo row
    "13784c3f24ca": "bullet",    # round bullet: a step beside a photo
    "bb0babedc849": "note",      # red "i"
    "15e050510b2d": "decor",     # pointing hand before a cross-reference
    "5b62bc6d3b62": "decor",     # torque wrench above a tightening-torque table
    # Ferrari's own key to these is document 01-03 "Symbols".
    "a8acdba5516e": "damage",    # red hand: risk of damage to the vehicle
    "b77d8638b894": "damage",    # red hand (Word-exported documents)
    "0e5b1e9ff170": "injury",    # warning triangle: risk of injury; often followed by a label line
    "808f8e183b66": "environment",   # green tree: environmental safety
}
ICON_MAX = 60        # px; anything larger is a figure
WARNING = {"note": "0Hinweis", "damage": "1Vorsicht", "injury": "2Warnung", "environment": "environment"}
# A warning's first line is sometimes just its label; the text follows.
# Where the label names a level, the heading follows it rather than the icon, so
# the two never disagree.
LABELS = {"CAUTION": "1Vorsicht", "ATTENTION": "1Vorsicht", "WARNING": "2Warnung", "DANGER": "3Gefahr",
          "IMPORTANT": None, "NOTE": None, "ENVIRONMENTAL SAFETY": None}
INLINE_TAGS = {"Link", "Span", "Superscript", "Subscript", "Enfasi (grassetto)", "Enfasi (corsivo)"}
BLOCK_TAGS = {"Table", "TR", "TD", "TH", "Figure", "P", "Div", "Document", "Root", "L", "LI", "LBody",
              "H1", "H2", "H3", "H4", "H5", "H6"}


def collapse(node: Node) -> Node:
    """Skip wrappers (div/span) that hold exactly one element."""
    while node.tag == "NonStruct" and len(node.children) == 1 and isinstance(node.children[0], Node):
        node = node.children[0]
    return node


def images(node) -> list[Image]:
    if isinstance(node, Image):
        return [node]
    if isinstance(node, Node):
        return [i for c in node.children for i in images(c)]
    return []


def is_icon(image: Image) -> bool:
    return max(image.px[0] or 0, image.px[1] or 0) <= ICON_MAX


def has_block(node: Node) -> bool:
    """Does this element contain block structure (as opposed to running text)?"""
    for child in node.children:
        if isinstance(child, Image) and not is_icon(child):
            return True
        if isinstance(child, Node):
            if child.tag == "Figure":
                if any(not is_icon(i) for i in images(child)):
                    return True
                continue
            if child.tag in BLOCK_TAGS:
                return True
            if has_block(child):
                return True
    return False


class Converter:
    def __init__(self, dom: Dom, year: int, model: str, codes: set[str] = frozenset()):
        self.dom = dom
        self.year, self.model = year, model
        self.codes = codes       # documents that exist, as "C5-03"
        self.media: dict[str, Image] = {}
        self.tools: dict[str, dict] = {}
        self.references: dict[str, str] = {}
        self.flags: collections.Counter = collections.Counter()
        self.counts: collections.Counter = collections.Counter()
        self.figure_ids = 0
        self.dead_links = 0
        self.toc: list[dict] = []
        self.tool_links: set[tuple[str, str]] = set()

    # ---- inline text -----------------------------------------------------

    def inline(self, node, state=None) -> str:
        """Running text as the small HTML the renderers already understand."""
        state = state if state is not None else {"last": " "}
        if isinstance(node, Text):
            text = node.text
            if node.wrapped and not state["last"].isspace() and not text[:1].isspace():
                text = " " + text
            if not text:
                return ""
            state["last"] = text[-1]
            escaped = html.escape(text, quote=False)
            return f"<b>{escaped}</b>" if node.bold and text.strip() else escaped
        if isinstance(node, Image):
            kind = ICONS.get(node.sha)
            if kind is None:
                self.flags[f"inline image {node.sha} {node.px[0]}x{node.px[1]}"] += 1
            return ""
        if isinstance(node, Target):
            return ""
        inner = "".join(self.inline(child, state) for child in node.children)
        if node.tag == "Link":
            uri = next((c.uri for c in node.children if isinstance(c, Target)), "")
            return self.link(uri, inner)
        if node.tag == "Superscript":
            return f"<sup>{inner}</sup>" if inner.strip() else inner
        if node.tag == "Subscript":
            return f"<sub>{inner}</sub>" if inner.strip() else inner
        return inner

    def link(self, uri: str, inner: str) -> str:
        label = re.sub(r"<[^>]+>", "", inner).strip()
        if not label:
            return inner
        # Every link on the site, tools included, points at another document
        # (a tool link opens the special-tools list).
        ref = re.search(r"link::SM_SM_([A-Z0-9]{2})([A-Z0-9]{2});", uri)
        code = f"{ref.group(1)}-{ref.group(2)}" if ref else None
        if code and code in self.codes:
            self.references[code] = html.unescape(label)
            # A tool link names the tool ("...-SpecialTools-...-AV8174"); aim at its
            # entry in the tools list (anchored there by link_tools).
            tool = re.search(r"SpecialTools.*-([A-Z]{1,3}\d\w*)$", uri)
            fragment = ""
            if tool:
                fragment = f"#tool-{tool.group(1)}"
                self.tool_links.add((code, tool.group(1)))
            return (f'<a class="qv qv-doc" href="/documents/{self.year}/{self.model}/'
                    f'{hkap_id(self.model, self.year, code)}{fragment}">{inner.strip()}</a>')
        self.flags[f"link kept as text: {uri[:90]}"] += 1
        self.dead_links += 1
        return inner

    def static(self, markup: str, para=True) -> dict | None:
        markup = re.sub(r"\s+", " ", markup).strip()
        markup = re.sub(r"</b>(\s*)<b>", r"\1", markup)
        if not re.sub(r"<[^>]+>", "", markup).strip():
            return None
        return {"type": "static", "inputs": {"html": markup, "para": para}}

    # ---- figures ---------------------------------------------------------

    def figure(self, image: Image) -> dict:
        key = str(image_id(self.model, image.sha))
        self.media[key] = image
        self.figure_ids += 1
        self.counts["figures"] += 1
        return {"type": "image", "inputs": {
            "id": f"fig{self.figure_ids}", "key": key, "title": "", "format": "jpg",
            "mediacloudSmall": key, "mediacloudNormal": key, "mediacloudLarge": key,
        }}

    # ---- blocks ----------------------------------------------------------

    def blocks(self, children: list, top=False) -> list[dict]:
        """Convert a run of sibling DOM nodes into content nodes."""
        out: list[dict] = []
        marker: str | None = None
        pending_inline: list = []

        def flush_inline():
            if pending_inline:
                state = {"last": " "}
                node = self.static("".join(self.inline(c, state) for c in pending_inline))
                pending_inline.clear()
                if node:
                    emit_text(node)

        def emit_text(node: dict):
            nonlocal marker
            kind, marker = marker, None
            if kind in ("step", "bullet"):
                self.counts["steps"] += 1
                node["inputs"]["para"] = False      # a list item, not a paragraph of its own
                if out and out[-1]["type"] == "list" and out[-1].get("_kind") == kind:
                    out[-1]["inputs"]["items"].append(node)
                else:
                    out.append({"type": "list", "inputs": {"items": [node]}, "_kind": kind})
            elif kind in WARNING:
                self.counts["notes"] += 1
                out.append({"type": "warning", "inputs": {"category": WARNING[kind], "children": [node]}})
            elif out and out[-1]["type"] == "warning" and self.label_only(out[-1]):
                # The text of a warning whose first line was just its label.
                out[-1]["inputs"]["children"].append(node)
            else:
                out.append(node)

        index = 0
        children = list(children)
        while index < len(children):
            child = children[index]
            index += 1
            if isinstance(child, (Text, Target)):
                pending_inline.append(child)
                continue
            if isinstance(child, Image):
                if is_icon(child):
                    kind = ICONS.get(child.sha)
                    if kind is None:
                        self.flags[f"unknown icon {child.sha} {child.px[0]}x{child.px[1]}"] += 1
                    elif kind != "decor":
                        flush_inline()
                        marker = kind
                else:
                    flush_inline()
                    out.append(self.figure(child))
                continue
            child = collapse(child)
            if child.tag in INLINE_TAGS or (child.tag not in BLOCK_TAGS and child.tag != "NonStruct" and not has_block(child)
                                            and pending_inline):
                pending_inline.append(child)
                continue
            flush_inline()
            if child.tag == "Table":
                self.table(child, out)
            elif not has_block(child) or (child.tag == "Figure" and all(is_icon(i) for i in images(child))):
                # A paragraph (P, or a Word style name, or a div of text).
                icons = [i for i in images(child) if ICONS.get(i.sha) not in (None, "decor")]
                if icons and marker is None:
                    marker = ICONS[icons[0].sha]
                for image in images(child):
                    if ICONS.get(image.sha) is None:
                        self.flags[f"unknown icon {image.sha} {image.px[0]}x{image.px[1]}"] += 1
                texts = [t for t in self.runs(child)]
                node = self.static(self.inline_no_icons(child))
                if node is None:
                    continue
                if (marker is None and texts and all(t.bold for t in texts if t.text.strip())
                        and len(child.text().strip()) <= 120 and not self.in_table):
                    # A heading: it owns the rest of this container.
                    # Written the way the Porsche documents write headings: an
                    # <h2>/<h3> with an id, in line with the blocks it heads.
                    title = re.sub(r"<[^>]+>", "", node["inputs"]["html"])
                    self.counts["sections"] += 1
                    anchor = f"section-{self.counts['sections']}"
                    level = min(2 + self.heading_depth, 4)
                    self.toc.append({"label": html.unescape(title), "anchor": anchor})
                    out.append({"type": "static", "inputs": {"html": f'<h{level} id="{anchor}">{title}</h{level}>', "para": False}})
                    self.heading_depth += 1
                    for block in self.blocks(children[index:]):
                        self.append(out, block)
                    self.heading_depth -= 1
                    index = len(children)
                else:
                    emit_text(node)
            else:
                inner = self.blocks(child.children)
                big = [c for c in child.children if isinstance(c, Node) and self.leads_with_figure(c)]
                if (inner and inner[0]["type"] == "image" and len(inner) > 1
                        and all(b["type"] in ("list", "warning", "static", "table") for b in inner[1:])):
                    # A photo with the instructions printed beside it: one step.
                    self.counts["photo_steps"] += 1
                    out.append({"type": "plot", "inputs": [{"position": None, "children": inner}]})
                else:
                    if marker and inner:
                        # The marker belongs to the first paragraph inside.
                        kind, marker = marker, None
                        first = inner[0]
                        if first["type"] == "static" and kind in ("step", "bullet"):
                            self.counts["steps"] += 1
                            first["inputs"]["para"] = False
                            inner[0] = {"type": "list", "inputs": {"items": [first]}, "_kind": kind}
                        elif first["type"] == "static" and kind in WARNING:
                            self.counts["notes"] += 1
                            inner[0] = {"type": "warning", "inputs": {"category": WARNING[kind], "children": [first]}}
                    for block in inner:
                        self.append(out, block)
        flush_inline()
        return out

    in_table = False
    heading_depth = 0

    @staticmethod
    def plain(node: dict) -> str:
        return html.unescape(re.sub(r"<[^>]+>", "", node["inputs"].get("html", ""))).strip()

    def label_only(self, warning: dict) -> bool:
        children = warning["inputs"]["children"]
        if len(children) == 1 and children[0]["type"] == "static" and self.plain(children[0]) in LABELS:
            warning["inputs"]["category"] = LABELS[self.plain(children[0])] or warning["inputs"]["category"]
            return True
        return False

    def append(self, out: list, block: dict):
        """Add a block, joining it to the previous one where they continue each other."""
        if out and block["type"] == "static" and out[-1]["type"] == "warning" and self.label_only(out[-1]):
            out[-1]["inputs"]["children"].append(block)
        elif out and block["type"] == "list" and out[-1]["type"] == "list" and out[-1].get("_kind") == block.get("_kind"):
            out[-1]["inputs"]["items"].extend(block["inputs"]["items"])
        elif out and block["type"] == "plot" and out[-1]["type"] == "plot":
            out[-1]["inputs"].extend(block["inputs"])
        else:
            out.append(block)

    def leads_with_figure(self, node: Node) -> bool:
        found = images(node)
        return bool(found) and not is_icon(found[0])

    def runs(self, node):
        for child in node.children:
            if isinstance(child, Text):
                yield child
            elif isinstance(child, Node):
                yield from self.runs(child)

    def inline_no_icons(self, node: Node) -> str:
        return self.inline(node, {"last": " "})

    # ---- tables ----------------------------------------------------------

    def table(self, table: Node, out: list):
        rows = [collapse(r) for r in table.walk() if r.tag == "TR" and self.owner(table, r)]
        grid = [[c for c in (collapse(x) if x.tag == "NonStruct" else x for x in row.children if isinstance(x, Node))
                 if c.tag in ("TD", "TH")] for row in rows]
        grid = [row for row in grid if row]
        if not grid:
            for block in self.blocks(table.children):
                self.append(out, block)
            return

        # The site lays pages out with one-cell tables; those aren't tables.
        if len(grid) == 1 and len(grid[0]) == 1:
            cell = Node("NonStruct", {}, grid[0][0].children)
            for block in self.blocks([cell] if has_block(cell) else cell.children):
                self.append(out, block)
            return

        # "A - Single heat exchanger" rows under a figure are its legend.
        if (out and out[-1]["type"] == "image" and "legend" not in out[-1]["inputs"]
                and all(len(row) == 3 and row[1].text().strip() == "-" for row in grid)):
            legend = []
            for row in grid:
                label = self.static(self.inline_no_icons(row[0]), para=False)
                text = self.static(self.inline_no_icons(row[2]), para=False)
                legend.append([label["inputs"]["html"] if label else "", text if text else ""])
            out[-1]["inputs"]["legend"] = legend
            self.counts["legend_rows"] += len(legend)
            return

        self.counts["tables"] += 1
        was, self.in_table = self.in_table, True
        columns = max(sum(c.attrs.get("ColSpan", 1) for c in row) for row in grid)
        header, data, title = [], [], None
        carry: dict[int, int] = {}      # column -> rows still covered by a row span
        body_started = False
        for row in grid:
            cells, column = [], 0
            texts = []
            for cell in row:
                while carry.get(column, 0) > 0:
                    carry[column] -= 1
                    cells.append("")
                    column += 1
                span = cell.attrs.get("ColSpan", 1)
                content = self.cell(cell)
                texts.append((cell, content))
                cells.append([content, span, 1] if span > 1 else content)
                for offset in range(span):
                    if cell.attrs.get("RowSpan", 1) > 1:
                        carry[column + offset] = cell.attrs["RowSpan"] - 1
                column += span
            while column < columns and carry.get(column, 0) > 0:
                carry[column] -= 1
                cells.append("")
                column += 1
            filled = [(c, content) for c, content in texts if content != ""]
            if not filled:
                continue            # a row holding only a decorative icon
            all_bold = all(all(t.bold for t in self.runs(c) if t.text.strip()) and c.text().strip() for c, _ in filled)
            if not body_started and all_bold and len(row) == 1 and title is None and not header:
                title = html.unescape(re.sub(r"<[^>]+>", "", self.inline_no_icons(row[0]))).strip()
                title = re.sub(r"\s+", " ", title)
            elif not body_started and all_bold:
                header.append(cells)
            else:
                body_started = True
                data.append(cells)
                self.counts["table_rows"] += 1
        self.in_table = was
        # Not page-wide: a small table (a torque value, say) stays as wide as its
        # content instead of stretching its columns across the page.
        inputs = {"data": data, "pgwide": False}
        if header:
            inputs["header"] = header
        if title:
            inputs["title"] = title
        out.append({"type": "table", "inputs": inputs})

    @staticmethod
    def owner(table: Node, row: Node) -> bool:
        """Is `row` a row of `table` itself, not of a table nested in a cell?"""
        def search(node, depth):
            for child in node.children:
                if not isinstance(child, Node):
                    continue
                if child is row:
                    return depth
                found = search(child, depth + (1 if child.tag == "Table" else 0))
                if found is not None:
                    return found
            return None
        return search(table, 0) == 0

    def cell(self, cell: Node):
        if not has_block(Node("x", {}, [c for c in cell.children])) or all(
                isinstance(c, Node) and collapse(c).tag == "P" and not has_block(collapse(c)) for c in cell.children):
            parts = []
            for child in cell.children:
                if isinstance(child, Node):
                    for image in images(child):
                        if ICONS.get(image.sha) is None:
                            self.flags[f"unknown icon {image.sha} {image.px[0]}x{image.px[1]}"] += 1
                    node = self.static(self.inline_no_icons(child), para=False)
                    if node:
                        parts.append(node["inputs"]["html"])
                elif isinstance(child, Text):
                    node = self.static(self.inline(child), para=False)
                    if node:
                        parts.append(node["inputs"]["html"])
            if not parts:
                return ""
            return {"type": "static", "inputs": {"html": "<br>".join(parts), "para": False}}
        inner = self.blocks(cell.children)
        if not inner:
            return ""
        return inner[0] if len(inner) == 1 else {"type": "mixed", "inputs": {"children": inner}}

    # ---- the document ----------------------------------------------------

    def document(self) -> dict:
        root = self.dom.root
        document = next((n for n in root.walk() if n.tag == "Document"), root)
        body = [c for c in document.children if isinstance(c, Node)]
        banner = ""
        chrome = []
        # The print view opens with a banner ("GTC4Lusso USA - <title> - Latest
        # Update: <date>") and a copyright box; neither is part of the document.
        while body and body[0].tag in ("Link", "Div") and (
                body[0].tag == "Link" or re.search(r"Latest Update:|Protected by copyright", body[0].text())):
            node = body.pop(0)
            if node.tag == "Div":
                chrome.append(node.text())
                if "Latest Update" in node.text():
                    banner = node.text().strip()
        self.chrome = chrome
        # What the PDF says, in reading order, before anything is rearranged.
        self.source_text = "".join(node.text() for node in body)

        # Code and title: the two blue bold paragraphs that open the body.
        code = title = ""
        if body:
            first = body[0]
            heads = []
            for node in first.walk():
                if node.tag == "P":
                    runs = list(self.runs(node))
                    if runs and all(r.color == (0.0, 0.0, 1.0) for r in runs if r.text.strip()):
                        heads.append(node)
                    if len(heads) == 2:
                        break
                    if not runs or not all(r.color == (0.0, 0.0, 1.0) for r in runs if r.text.strip()):
                        break
            if len(heads) == 2:
                code, title = heads[0].text().strip(), re.sub(r"\s+", " ", heads[1].text()).strip()
                self.remove(first, heads)
        self.heading_text = [code, title]

        content = self.blocks(body, top=True)
        self.number(content)
        # One step per block: the app follows the reading position block by block,
        # so this is what lets it keep each step's photo beside the step being read.
        content = [piece for block in content for piece in (
            [{"type": "plot", "inputs": [item]} for item in block["inputs"]] if block["type"] == "plot" else [block])]
        self.strip(content)
        updated = re.search(r"Latest Update:\s*(\d{4}-\d{2}-\d{2})", banner)
        return {
            "code": code,
            "title": title,
            "updated": updated.group(1) if updated else None,
            "content": content,
            "toc": self.toc,
            "references": self.references,
        }

    def remove(self, root: Node, targets: list):
        for node in root.walk():
            node.children = [c for c in node.children if not any(c is t for t in targets)]

    def number(self, blocks: list):
        """Number the photo steps 1..n under each heading."""
        count = 0
        for block in blocks:
            if block["type"] == "static" and re.match(r"<h\d", block["inputs"]["html"]):
                count = 0
            elif block["type"] == "plot":
                for item in block["inputs"]:
                    count += 1
                    item["position"] = str(count)

    def strip(self, value):
        if isinstance(value, dict):
            value.pop("_kind", None)
            for item in value.values():
                self.strip(item)
        elif isinstance(value, list):
            for item in value:
                self.strip(item)


# ---- output text, for checking ----------------------------------------------

def output_text(value, out: list):
    """All text in a converted document, in order, markup removed."""
    if isinstance(value, str):
        out.append(html.unescape(re.sub(r"<[^>]+>", "", value)))
    elif isinstance(value, list):
        for item in value:
            output_text(item, out)
    elif isinstance(value, dict):
        kind = value.get("type")
        inputs = value.get("inputs")
        if kind == "static":
            output_text(inputs.get("html", ""), out)
        elif kind == "image":
            for label, text in inputs.get("legend", []):
                output_text(label, out)
                out.append("-")       # the separator column the legend table printed
                output_text(text, out)
        elif kind == "table":
            if inputs.get("title"):
                out.append(inputs["title"])
            output_text(inputs.get("header", []), out)
            output_text(inputs.get("data", []), out)
        elif kind == "section":
            out.append(inputs.get("title") or "")
            output_text(inputs.get("children", []), out)
        elif kind == "plot":
            for item in inputs:
                output_text(item.get("children", []), out)
        elif kind in ("list",):
            output_text(inputs.get("items", []), out)
        elif kind in ("warning", "mixed", "paragraph"):
            output_text(inputs.get("children", []), out)


def squeeze(text: str) -> str:
    return re.sub(r"\s+", "", text)


NUMBER = re.compile(r"\d+(?:[.,]\d+)*")
CHROME_LINES = re.compile(
    r"^\s*(\d{1,2}/\d{1,2}/\d{4}\s+FERRARI Technical Documentation.*|FERRARI Technical Documentation\s*-?\s*"
    r"|\d{1,2}/\d{1,2}/\d{4}|https://modiscs\.ferrari\.it/\S*(\s+\d+/\d+)?|\d+/\d+)\s*$")


def check(path: str, dom: Dom, converter: Converter, document: dict) -> dict:
    produced: list[str] = [document["code"], document["title"]]
    output_text(document["content"], produced)
    produced_text = squeeze("".join(produced))

    # 1. Against the tagged text, in reading order, character for character.
    source_text = squeeze(converter.source_text)
    missing = added = 0
    samples = []
    if source_text != produced_text:
        matcher = difflib.SequenceMatcher(None, source_text, produced_text, autojunk=False)
        for op, a1, a2, b1, b2 in matcher.get_opcodes():
            if op == "equal":
                continue
            missing += a2 - a1
            added += b2 - b1
            if len(samples) < 8:
                samples.append({"pdf": source_text[max(0, a1 - 20):a2 + 20], "output": produced_text[max(0, b1 - 20):b2 + 20]})

    # 2. Against an independent reader (poppler): every number in the PDF,
    #    page furniture aside, must be in the output the same number of times.
    raw = subprocess.run(["pdftotext", "-layout", path, "-"], capture_output=True, text=True).stdout
    lines = [line for line in raw.replace("\f", "\n").split("\n") if not CHROME_LINES.match(line)]
    independent = "\n".join(lines)
    for chunk in converter.chrome:
        for number in NUMBER.findall(chunk):
            independent = independent.replace(number, "", 1)
    want = collections.Counter(NUMBER.findall(independent))
    for repeat in dom.repeats:
        want.subtract(NUMBER.findall(repeat))
    got = collections.Counter(NUMBER.findall(" ".join(produced)))
    number_missing = {k: v - got.get(k, 0) for k, v in want.items() if v > got.get(k, 0)}
    number_extra = {k: v - want.get(k, 0) for k, v in got.items() if v > want.get(k, 0)}
    # Step numbers are ours ("position"), and aren't in `produced`, so nothing to discount.

    # 3. Untagged text should be nothing but page furniture.
    tagged = squeeze(dom.root.text())
    untagged = [t for t in dom.all_text if squeeze(t) and squeeze(t) not in tagged]
    furniture = squeeze("FERRARI Technical Documentation -" + document["code"] + document["title"])
    stray = [t for t in untagged if not (
        squeeze(t) in furniture or re.fullmatch(r"[\d/\s]+|https?://\S+|[\ue000-\uf8ff\s]+", t.strip()))]

    return {
        "characters": len(source_text),
        "characters_missing": missing,
        "characters_added": added,
        "character_diffs": samples,
        "numbers": sum(want.values()),
        "numbers_missing": number_missing,
        "numbers_extra": number_extra,
        "untagged_text": sorted(set(stray))[:10],
        "reprinted_headers_dropped": len(dom.repeats),
        "overprints_dropped": len(dom.overprints),
    }


# ---- images -----------------------------------------------------------------

def save_image(image: Image, path_stem: str) -> str:
    stream = image.stream
    filters = stream.get_filters()
    names = [str(getattr(f[0], "name", f[0])) for f in filters]
    if names and names[-1] == "DCTDecode" and len(names) == 1:
        with open(path_stem + ".jpg", "wb") as handle:
            handle.write(stream.get_rawdata())
        return ".jpg"
    data = stream.get_data()
    width, height = image.px
    channels = len(data) // (width * height) if width and height else 0
    if channels not in (1, 3):
        return ""
    raw = b"".join(b"\x00" + data[y * width * channels:(y + 1) * width * channels] for y in range(height))

    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2 if channels == 3 else 0, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    with open(path_stem + ".png", "wb") as handle:
        handle.write(png)
    return ".png"


def hkap_id(model: str, year: int, code: str) -> str:
    """The loader's id for a document (ferrari_loader.rs: generate_hkap_id)."""
    return "ferrari-" + uuid.uuid5(uuid.NAMESPACE_DNS, f"ferrari-{model}-{year}-{code}").hex


def image_id(model: str, sha: str) -> int:
    """A stable id for a figure in the shared workshop-image table, kept in the
    upper half of the positive range, away from the ids the Porsche data uses."""
    digest = uuid.uuid5(uuid.NAMESPACE_DNS, f"ferrari-{model}-image-{sha}").int
    return 0x40000000 | (digest & 0x3FFFFFFF)


def convert(path: str, out_dir: str, year: int, model: str, codes: set[str]) -> dict:
    dom = Dom(path)
    converter = Converter(dom, year, model, codes)
    document = converter.document()
    report = check(path, dom, converter, document)
    report.update({
        "file": os.path.basename(path),
        "code": document["code"],
        "pages": dom.page_count,
        "counts": dict(converter.counts),
        "flags": dict(converter.flags),
        "references": len(document["references"]),
        "tool_links": sorted(converter.tool_links),
    })
    os.makedirs(os.path.join(out_dir, "media"), exist_ok=True)
    images = {}
    for key, image in converter.media.items():
        extension = save_image(image, os.path.join(out_dir, "media", key))
        if extension:
            images[key] = f"media/{key}{extension}"
        else:
            report["flags"][f"image not saved {key}"] = 1
    # Links to documents that aren't in the set stay as text; that's faithful,
    # so it doesn't fail the document.
    blocking = {k: v for k, v in report["flags"].items() if not k.startswith("link kept as text")}
    report["passed"] = not (report["characters_missing"] or report["characters_added"] or report["numbers_missing"]
                            or report["numbers_extra"] or report["untagged_text"] or blocking
                            or not document["content"])
    produced: list[str] = []
    output_text(document["content"], produced)
    # A glyph the PDF maps to no real character (a ligature with a broken
    # mapping, say) can't be trusted as text; such a document stays a PDF.
    unreadable = len(re.findall(r"[\x00-\x08\x0b-\x1f\ufffd]", "".join(produced)))
    if unreadable:
        report["flags"]["unreadable characters"] = unreadable
        report["passed"] = False
    document.update({
        "passed": report["passed"],
        "images": images,
        "text": re.sub(r"[ \t]+", " ", "\n".join(t.strip() for t in produced if t.strip())),
    })
    name = os.path.splitext(os.path.basename(path))[0]
    with open(os.path.join(out_dir, name + ".json"), "w") as handle:
        json.dump(document, handle, indent=1, ensure_ascii=False)
    report["output"] = name + ".json"
    return report


def link_tools(out_dir: str, reports: list[dict]) -> tuple[int, int]:
    """Anchor each tool that some document links to at its entry in the tools
    list it lives in, so the link lands on the tool rather than the top of the
    list. The entry is the first step (or block) that names the tool."""
    wanted: dict[str, set[str]] = collections.defaultdict(set)
    for report in reports:
        for code, tool in report.get("tool_links", []):
            wanted[code].add(tool)
    by_code = {r["file"][:-4].split(" ")[0]: r["output"] for r in reports if r.get("output")}
    found = missing = 0
    for code, tools in wanted.items():
        if code not in by_code:
            missing += len(tools)
            continue
        path = os.path.join(out_dir, by_code[code])
        document = json.load(open(path))

        def text_of(value) -> str:
            parts: list[str] = []
            output_text(value, parts)
            return squeeze("".join(parts))

        for tool in sorted(tools):
            anchor = f"tool-{tool}"
            placed = False
            for index, block in enumerate(document["content"]):
                if block["type"] == "plot":
                    for item in block["inputs"]:
                        if tool in text_of(item["children"]) and not item.get("id"):
                            item["id"] = anchor
                            placed = True
                            break
                elif block["type"] != "anchor" and tool in text_of(block):
                    document["content"].insert(index, {"type": "anchor", "inputs": {"id": anchor}})
                    placed = True
                if placed:
                    break
            found += placed
            missing += not placed
        # The app scrolls to top-level blocks, so an anchored step starts its own.
        content = []
        for block in document["content"]:
            if block["type"] != "plot":
                content.append(block)
                continue
            run: list[dict] = []
            for item in block["inputs"]:
                if run and str(item.get("id") or "").startswith("tool-"):
                    content.append({"type": "plot", "inputs": run})
                    run = []
                run.append(item)
            content.append({"type": "plot", "inputs": run})
        document["content"] = content
        with open(path, "w") as handle:
            json.dump(document, handle, indent=1, ensure_ascii=False)
    return found, missing


def _worker(args):
    path = args[0]
    try:
        return convert(*args)
    except Exception as error:      # reported, not hidden
        return {"file": os.path.basename(path), "passed": False, "error": f"{type(error).__name__}: {error}"}


if __name__ == "__main__":
    import argparse
    import logging
    import multiprocessing
    import shutil
    logging.disable(logging.WARNING)
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--year", type=int, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("source")
    parser.add_argument("out")
    args = parser.parse_args()
    paths = sorted(os.path.join(root, name) for root, _, names in os.walk(args.source)
                   for name in names if name.lower().endswith(".pdf"))
    # A document's code is its file name up to the first space ("C5-03 Transmission housing.pdf").
    codes = {os.path.basename(p)[:-4].split(" ")[0] for p in paths}
    shutil.rmtree(args.out, ignore_errors=True)
    os.makedirs(args.out)
    with multiprocessing.Pool() as pool:
        reports = pool.map(_worker, [(p, args.out, args.year, args.model, codes) for p in paths])
    with open(os.path.join(args.out, "report.json"), "w") as handle:
        json.dump(reports, handle, indent=1, ensure_ascii=False)
    anchored, unanchored = link_tools(args.out, reports)
    for r in reports:
        if "error" in r:
            print(f"pdf   {r['file'][:60]:60} {r['error']}")
        elif not r["passed"]:
            print(f"pdf   {r['file'][:60]:60} chars -{r['characters_missing']} +{r['characters_added']}  "
                  f"numbers -{sum(r['numbers_missing'].values())} +{sum(r['numbers_extra'].values())}  "
                  f"flags {list(r['flags'])[:2]}")
    passed = sum(1 for r in reports if r["passed"])
    dead = sum(v for r in reports for k, v in r.get("flags", {}).items() if k.startswith("link kept as text"))
    print(f"{passed} of {len(reports)} documents structured; {len(reports) - passed} stay PDF; "
          f"{dead} links to documents outside the set kept as text; "
          f"{anchored} tools anchored in their lists, {unanchored} not found there")
