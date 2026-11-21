"""Convert the split Audi R8 workshop-manual PDFs into the structured document
format the Porsche documents use, and check each result against its PDF.

    python r8_extract.py SPLIT_DIR OUT_DIR

SPLIT_DIR is what r8_split.py wrote (the PDFs and manifest.json). Writes, per
document, OUT_DIR/<hkap id>.json (content tree, contents list, search text,
figures, and whether it passed the checks), the figures under OUT_DIR/media/,
and OUT_DIR/report.json. `workbook load-audi --structured OUT_DIR` loads every
document that passed as a structured document and the rest as PDFs.

The PDFs aren't tagged, so structure is read from the layout, which is
machine-made and regular (see r8_pdf_lines.py): headings by size, steps and
bullets by their marker, notes and warnings by their icon and box, tables by
their ruled grid. Nothing is paraphrased or generated. A document passes only
if its text matches the PDF character for character in reading order, every
number matches what poppler's pdftotext finds, and nothing went unrecognised.
"""
from __future__ import annotations

import collections
import difflib
import html
import json
import os
import re
import subprocess
import sys

from ferrari_extract import NUMBER, image_id, save_image, squeeze
from r8_pdf_lines import TAB, Image, Line, Link, Page, Rule, read

YEAR, MODEL = 2018, "R8"
LOGO = (604, 367)
ICONS = {(801, 800): "note", (904, 800): "warning"}
LEVELS = {"WARNING": "2Warnung", "DANGER": "3Gefahr", "CAUTION": "1Vorsicht", "NOTE": "0Hinweis"}
MARKERS = "–•♦❑"
SOFT_HYPHEN = "‐"      # how these PDFs mark a word broken at a line end
BODY_TOP, BODY_BOTTOM = 778, 50


# ---- page geometry ------------------------------------------------------------

class VLine:
    """One printed line of body text, pieces joined."""

    def __init__(self, line: Line, page: Page, base: float):
        self.page = page
        self.y = line.y
        self.x = line.x
        self.nx = line.x - base
        self.size = line.size
        self.runs = list(line.runs)
        self.box = None
        self.key = (round(line.y, 1), round(line.x, 1))     # its first piece, as drawn

    @property
    def top(self) -> float:
        return self.y + self.size

    @property
    def text(self) -> str:
        return "".join(r.text for r in self.runs)

    def shown(self):
        return [r for r in self.runs if r.text.strip() and r.text.strip(TAB + " ") not in tuple(MARKERS)]

    @property
    def bold(self) -> bool:
        return bool(self.shown()) and all(r.bold for r in self.shown())

    @property
    def italic(self) -> bool:
        return bool(self.shown()) and all(r.italic for r in self.shown())

    @property
    def red(self) -> bool:
        return bool(self.shown()) and all(r.red for r in self.shown())


def absorb(current, item: Line) -> bool:
    """Add a piece to the printed line it belongs to: the next piece on the same
    baseline, or small raised/lowered characters set against it."""
    if current is None:
        return False
    dy = item.y - current.y
    follows = -1.5 <= item.x - current.runs[-1].end <= 4.5
    if 1.6 <= abs(dy) < 6.5 and follows and len(item.text.strip()) <= 4:
        for run in item.runs:
            run.shift = "sup" if dy > 0 else "sub"
        current.runs.extend(item.runs)
        return True
    if 1.6 <= abs(dy) < 6.5 and follows and len(current.text.strip()) <= 4 and len(current.runs) == 1:
        # The line opened with the raised or lowered character (the "2" of a
        # 1/2 that wrapped); the text after it sets the baseline.
        current.runs[0].shift = "sub" if dy > 0 else "sup"
        current.y = item.y
        current.runs.extend(item.runs)
        return True
    if abs(dy) < 1.6 and -2 <= item.x - current.runs[-1].end <= 24:
        current.runs.extend(item.runs)
        return True
    return False


class Figure:
    def __init__(self, image: Image, page: Page):
        self.image, self.page = image, page
        self.top = image.y + image.h + 15      # sorts ahead of the line beside its top edge


class Icon:
    def __init__(self, image: Image, page: Page, kind: str):
        self.image, self.page, self.kind = image, page, kind
        self.top = image.y + image.h + 2
        self.box = None


class Table:
    def __init__(self, node: dict, top: float, page: Page, texts: list[str], first):
        self.node, self.top, self.page, self.texts = node, top, page, texts
        self.first = first        # its first line, to place it in drawing order


def rectangles(rules: list[Rule]) -> tuple[list[tuple], list[Rule]]:
    """Boxes drawn as four strokes in a row (figure frames, warning boxes, the
    box round an on-screen label), and the rules left over (tables)."""
    boxes, rest, i = [], [], 0
    while i < len(rules):
        group = rules[i:i + 4]
        if len(group) == 4:
            xs = [v for r in group for v in (r.x0, r.x1)]
            ys = [v for r in group for v in (r.y0, r.y1)]
            box = (min(xs), min(ys), max(xs), max(ys))
            closed = (sum(r.horizontal for r in group) == 2 and sum(r.vertical for r in group) == 2
                      and all(abs(abs(r.x1 - r.x0) - (box[2] - box[0])) < 2.5 for r in group if r.horizontal)
                      and all(abs(abs(r.y1 - r.y0) - (box[3] - box[1])) < 2.5 for r in group if r.vertical))
            if closed:
                boxes.append(box)
                i += 4
                continue
        rest.append(rules[i])
        i += 1
    return boxes, rest


def inside(box, x, y, pad=1.5) -> bool:
    return box[0] - pad <= x <= box[2] + pad and box[1] - pad <= y <= box[3] + pad


def uniq(values: list[float], tolerance: float) -> list[float]:
    out: list[float] = []
    for value in sorted(values):
        if not out or value - out[-1] > tolerance:
            out.append(value)
    return out


class Converter:
    def __init__(self, pages: list[Page]):
        self.pages = pages
        self.flags: collections.Counter = collections.Counter()
        self.counts: collections.Counter = collections.Counter()
        self.media: dict[str, Image] = {}
        self.toc: list[dict] = []
        self.anchors: list[tuple] = []        # (page number 1-based, fraction from top, anchor id)
        self.source: list[str] = []           # body text in the order the PDF draws it
        self.source_tables: list[str] = []    # each table's text
        self.source_flow_skip: list[tuple] = []   # where the tables sit in `source`
        self.figure_ids = 0
        self.title = ""

    # ---- pass 1: each page as elements in reading order ---------------------

    def elements(self) -> list:
        out = []
        for page in self.pages:
            out.extend(self.page_elements(page))
        return out

    def page_elements(self, page: Page) -> list:
        logo = next((i for i in page.items if isinstance(i, Image) and i.px == LOGO), None)
        base = 70.9 if logo is not None and logo.x < 300 and False else None
        # Left-hand and right-hand pages have different margins; the first body
        # line at the margin tells which.
        body = [i for i in page.items if not (
            (isinstance(i, Line) and (i.y > BODY_TOP or i.y < BODY_BOTTOM))
            or (isinstance(i, Image) and i.px == LOGO)
            or (isinstance(i, Rule) and (i.red or max(i.y0, i.y1) > BODY_TOP or min(i.y0, i.y1) < BODY_BOTTOM + 2.5)))]
        lines = [i for i in body if isinstance(i, Line)]
        if base is None:
            base = 70.9 if logo is not None and logo.x > 300 else 42.5
            if logo is None and lines:
                base = 70.9 if min(l.x for l in lines) > 60 else 42.5
        boxes, table_rules = rectangles([i for i in body if isinstance(i, Rule)])
        images = [i for i in body if isinstance(i, Image)]
        frames, warning_boxes, other_boxes = [], [], []
        for box in boxes:
            if box[3] - box[1] < 14:
                continue                                    # the box round an on-screen label
            held = [im for im in images if inside(box, im.x + im.w / 2, im.y + im.h / 2)]
            if any(ICONS.get(im.px) == "warning" for im in held):
                warning_boxes.append(box)
            elif any(im.w > 100 for im in held):
                frames.append(box)
            else:
                other_boxes.append(box)
        for box in other_boxes:
            # A box with neither figure nor warning icon: a table drawn as one cell.
            table_rules.extend([Rule(box[0], box[1], box[2], box[1]), Rule(box[0], box[3], box[2], box[3]),
                                Rule(box[0], box[1], box[0], box[3]), Rule(box[2], box[1], box[2], box[3])])

        elements: list = []
        tables = self.tables(table_rules, lines, page)
        in_table = {id(l) for t, members in tables for l in members}
        elements.extend(t for t, _ in tables)

        # Join the pieces of each printed line (a line is drawn in pieces
        # wherever a link or a boxed label starts and stops).
        current: VLine | None = None
        for item in body:
            if isinstance(item, Line):
                if id(item) in in_table:
                    current = None
                    continue
                if absorb(current, item):
                    continue
                current = VLine(item, page, base)
                current.box = next((b for b in warning_boxes if inside(b, item.x, item.y)), None)
                elements.append(current)
            elif isinstance(item, Image):
                kind = ICONS.get(item.px)
                if kind:
                    icon = Icon(item, page, kind)
                    icon.box = next((b for b in warning_boxes if inside(b, item.x + 2, item.y + 2)), None)
                    elements.append(icon)
                elif item.w > 100:
                    elements.append(Figure(item, page))
                else:
                    self.flags[f"unknown small image {item.px[0]}x{item.px[1]}"] += 1
        # What the PDF says, in the order it draws it (tables row by row).
        order = {id(item): n for n, item in enumerate(body)}
        first_piece = {}
        current = None
        for item in body:
            if isinstance(item, Line) and id(item) not in in_table:
                first_piece.setdefault((round(item.y, 1), round(item.x, 1)), order[id(item)])
        def drawn_at(e):
            if isinstance(e, Table):
                return order[id(e.first)]
            return first_piece.get(e.key, 0)
        drawn: list = sorted((e for e in elements if isinstance(e, (VLine, Table))), key=drawn_at)
        for element in drawn:
            if isinstance(element, VLine):
                self.source.append(element.text)
            else:
                self.source.extend(element.texts)
                self.source_tables.append(dehyphenated(element.texts))
                self.source_flow_skip.append((len(self.source) - len(element.texts), len(self.source)))
        elements.sort(key=lambda e: -e.top)
        return elements

    def tables(self, rules: list[Rule], lines: list[Line], page: Page) -> list[tuple]:
        """Ruled grids: cells are the gaps between the rules, text goes to the
        cell it sits in."""
        rules = [r for r in rules if r.horizontal or r.vertical]
        if not rules:
            return []
        # Group rules that touch into separate tables.
        groups: list[list[Rule]] = []
        for rule in sorted(rules, key=lambda r: -max(r.y0, r.y1)):
            top, bottom = max(rule.y0, rule.y1), min(rule.y0, rule.y1)
            for group in groups:
                g_bottom = min(min(r.y0, r.y1) for r in group)
                if top >= g_bottom - 3:
                    group.append(rule)
                    break
            else:
                groups.append([rule])
        out = []
        for group in groups:
            xs = [v for r in group for v in (r.x0, r.x1)]
            ys = [v for r in group for v in (r.y0, r.y1)]
            box = (min(xs), min(ys), max(xs), max(ys))
            members = [l for l in lines if inside(box, l.x, l.y + 2, pad=0.5)]
            if not any(r.vertical for r in group):
                ruled = self.headed_table(group, lines, page)
                if ruled:
                    out.append(ruled)
                continue
            if not members:
                continue
            cols = uniq([box[0], box[2]] + [r.x0 for r in group if r.vertical], 2.5)
            rows = uniq([box[1], box[3]] + [r.y0 for r in group if r.horizontal], 3.5)[::-1]   # top to bottom
            position = {id(item): n for n, item in enumerate(page.items)}
            grid: dict[tuple, list[Line]] = collections.defaultdict(list)
            for line in members:
                row = max((i for i in range(len(rows) - 1) if rows[i] >= line.y + 2), default=0)
                row = min(row, len(rows) - 2)
                col = max((i for i in range(len(cols) - 1) if cols[i] <= line.x + 1), default=0)
                col = min(col, len(cols) - 2)
                grid[(row, col)].append(line)
            header, data, texts = [], [], []
            body_started = False

            def ruled(y: float, col: int) -> bool:
                """Is there a rule across this column at this height?"""
                mid = (cols[col] + cols[col + 1]) / 2
                return any(r.horizontal and abs(r.y0 - y) < 3.5
                           and min(r.x0, r.x1) - 1 <= mid <= max(r.x0, r.x1) + 1 for r in group)

            taken: set[tuple] = set()      # cells covered by a cell that spans down from above
            for row in range(len(rows) - 1):
                mid = (rows[row] + rows[row + 1]) / 2
                cells, col = [], 0
                bold = []
                while col < len(cols) - 1:
                    if (row, col) in taken:
                        cells.append("")
                        col += 1
                        continue
                    span = 1
                    # No rule between two columns on this row: one cell spans them.
                    while col + span < len(cols) - 1 and (row, col + span) not in taken and not any(
                            r.vertical and abs(r.x0 - cols[col + span]) < 2.5
                            and min(r.y0, r.y1) - 1 <= mid <= max(r.y0, r.y1) + 1 for r in group):
                        span += 1
                    # No rule under the cell: it runs on down into the next row. Its
                    # text stays in its first row; the rows below get an empty cell.
                    depth = 1
                    while row + depth < len(rows) - 1 and not any(ruled(rows[row + depth], c) for c in range(col, col + span)):
                        depth += 1
                    held = [l for r in range(row, row + depth) for c in range(col, col + span) for l in grid.get((r, c), [])]
                    for r in range(row + 1, row + depth):
                        for c in range(col, col + span):
                            taken.add((r, c))
                    held.sort(key=lambda l: position[id(l)])     # drawing order
                    vlines = self.join_pieces(held, page)
                    markup = self.markup(vlines)
                    texts.extend(v.text for v in vlines)
                    if vlines:
                        bold.append(all(v.bold for v in vlines))
                    node = {"type": "static", "inputs": {"html": markup, "para": False}} if markup else ""
                    cells.append([node, span, 1] if span > 1 else node)
                    col += span
                if not any(c != "" for c in cells):
                    continue
                if not body_started and bold and all(bold):
                    header.append(cells)
                else:
                    body_started = True
                    data.append(cells)
            if not data and header:
                data, header = header, []
            self.counts["tables"] += 1
            inputs = {"data": data, "pgwide": False}
            if header:
                inputs["header"] = header
            out.append((Table({"type": "table", "inputs": inputs}, box[3], page, texts, members[0]), members))
        return out

    def headed_table(self, group: list[Rule], lines: list[Line], page: Page):
        """A table drawn with nothing but a rule under its header. The rule is
        drawn in one segment per column, which gives the columns; rows are set
        apart by a wider gap than the lines within a row."""
        rule_y = max(r.y0 for r in group)
        cols = uniq([v for r in group for v in (r.x0, r.x1)], 2.5)
        if len(cols) < 3 or max(r.y0 for r in group) - min(r.y0 for r in group) > 2:
            return None
        left, right = cols[0], cols[-1]
        header = [l for l in lines if rule_y < l.y < rule_y + 34 and left - 1 <= l.x <= right and l.bold]
        # The header is the bold lines directly above the rule.
        header.sort(key=lambda l: -l.y)
        kept, last_y = [], None
        for line in sorted(header, key=lambda l: l.y):
            if last_y is not None and line.y - last_y > 12:
                break
            kept.append(line)
            last_y = line.y
        header = kept
        body = []
        # An icon or figure below the header is past the table too.
        floor = max((i.y + i.h for i in page.items if isinstance(i, Image) and i.y + i.h < rule_y and i.x < right),
                    default=-1)
        for line in sorted((l for l in lines if l.y < rule_y), key=lambda l: -l.y):
            if line.y <= floor + 2:
                break
            # The table's text is inset from the margin; the first line back at
            # the margin (or a heading) is past the table.
            if line.x < left + 1 or line.size >= 13 or line.x > right:
                break
            body.append(line)
        if not header or not body:
            return None

        position = {id(item): n for n, item in enumerate(page.items)}

        def column(line: Line) -> int:
            return max((i for i in range(len(cols) - 1) if cols[i] <= line.x + 1), default=0)

        def row_cells(row_lines: list[Line]):
            cells, row_texts = [], []
            for col in range(len(cols) - 1):
                # (in drawing order, which keeps a footnote mark after its number)
                held = sorted((l for l in row_lines if column(l) == col), key=lambda l: position[id(l)])
                vlines = self.join_pieces(held, page)
                markup = self.markup(vlines)
                row_texts.extend(v.text for v in vlines)
                cells.append({"type": "static", "inputs": {"html": markup, "para": False}} if markup else "")
            return cells, row_texts

        texts: list[str] = []
        head_cells, head_texts = row_cells(header)
        texts.extend(head_texts)
        rows, current, last_y = [], [], None
        for line in body:
            if last_y is not None and last_y - line.y > 12 and current:
                rows.append(current)
                current = []
            current.append(line)
            last_y = line.y if last_y is None or line.y < last_y else last_y
        if current:
            rows.append(current)
        data = []
        for row in rows:
            cells, row_texts = row_cells(row)
            data.append(cells)
            texts.extend(row_texts)
        self.counts["tables"] += 1
        members = header + body
        first = min(members, key=lambda l: position[id(l)])
        node = {"type": "table", "inputs": {"data": data, "pgwide": False, "header": [head_cells]}}
        return Table(node, max(l.y + l.size for l in header), page, texts, first), members

    def join_pieces(self, lines: list[Line], page: Page) -> list[VLine]:
        out: list[VLine] = []
        for line in lines:
            if not absorb(out[-1] if out else None, line):
                out.append(VLine(line, page, 0))
        return out

    # ---- text ---------------------------------------------------------------

    def markup(self, lines: list[VLine], plain_style=False, strip_marker=True) -> str:
        """Lines of one paragraph as inline HTML: words broken at a line end are
        rejoined, bold/italic kept (unless the whole block is styled, as in a
        warning), links kept."""
        parts: list[str] = []
        tail = ""
        for index, line in enumerate(lines):
            piece = ""
            for n, run in enumerate(line.runs):
                text = run.text
                if n == 0 and strip_marker and text[:1] in MARKERS:
                    # The marker itself is layout; a later line that starts with one
                    # (a bullet inside a table cell) starts a new line here too.
                    text = text[1:]
                    if index:
                        piece += "<br>"
                text = text.replace(TAB, " ")
                if not text:
                    continue
                escaped = html.escape(text, quote=False)
                href = self.href(run, line) if run.red else None
                if href:
                    escaped = f'<a class="qv qv-doc" href="{href}">{escaped}</a>'
                if run.shift and text.strip():
                    escaped = f"<{run.shift}>{escaped}</{run.shift}>"
                elif not href and not plain_style and text.strip():
                    if run.bold:
                        escaped = f"<b>{escaped}</b>"
                    if run.italic:
                        escaped = f"<i>{escaped}</i>"
                piece += escaped
            piece = piece.strip() if index else piece.lstrip()
            if not piece:
                continue
            if tail.endswith(SOFT_HYPHEN) and not piece.startswith("<br>"):
                parts[-1] = parts[-1][:-len(SOFT_HYPHEN)] if parts[-1].endswith(SOFT_HYPHEN) else re.sub(
                    SOFT_HYPHEN + r"((?:</[abi]>)+)$", r"\1", parts[-1])
                parts.append(piece)
            else:
                parts.append((" " if parts else "") + piece)
            tail = re.sub(r"<[^>]+>", "", piece).rstrip()
        markup = "".join(parts).strip()
        markup = re.sub(r"\s+", " ", markup)
        for tag in ("b", "i"):
            markup = re.sub(rf"</{tag}>(\s*)<{tag}>", r"\1", markup)
        # A link that wraps is drawn as two; make it one again.
        markup = re.sub(r'(<a class="qv qv-doc" href="([^"]+)">)([^<]*)</a>(\s*)<a class="qv qv-doc" href="\2">',
                        r"\1\3\4", markup)
        return markup

    def href(self, run, line: VLine) -> str | None:
        for link in line.page.links:
            x0, y0, x1, y1 = link.rect
            if x0 - 2 <= run.x + 1 <= x1 + 2 and y0 - 3 <= line.y + 3 <= y1 + 3 and link.uri:
                match = re.search(r"/documents/\d+/[^/]+/[\w-]+(#\S*)?$", link.uri)
                if match:
                    return match.group(0)
        self.flags["red text without a link"] += 1
        return None

    def static(self, lines: list[VLine], para=True, plain_style=False) -> dict | None:
        markup = self.markup(lines, plain_style=plain_style)
        if not re.sub(r"<[^>]+>", "", markup).strip():
            return None
        first = lines[0]
        return {"type": "static", "inputs": {"html": markup, "para": para},
                "_at": [first.page.number + 1, round((first.page.height - first.top) / first.page.height, 4)]}

    def figure(self, image: Image) -> dict:
        key = str(image_id(MODEL, image.sha))
        self.media[key] = image
        self.figure_ids += 1
        self.counts["figures"] += 1
        return {"type": "image", "inputs": {
            "id": f"fig{self.figure_ids}", "key": key, "title": "", "format": "png",
            "mediacloudSmall": key, "mediacloudNormal": key, "mediacloudLarge": key,
        }}

    # ---- pass 2: elements into blocks -----------------------------------------

    def document(self) -> dict:
        elements = self.elements()
        content: list[dict] = []
        step: dict | None = None          # the open step (a plot item)
        holder: dict | None = None        # an open note/warning, or legend entry, taking bullets
        pending_figure: dict | None = None
        last_item: dict | None = None     # the last bullet, for ❑ / ♦ nesting

        def close():
            nonlocal step, holder, last_item
            step = holder = last_item = None

        def emit(block: dict, top_level=False):
            """Put a block where it belongs: in the open step, else at top level."""
            nonlocal pending_figure
            if step is not None and not top_level:
                step["children"].append(block)
                return
            if pending_figure is not None:
                content.append(pending_figure)
                pending_figure = None
            content.append(block)

        def bullets(target_children: list, node: dict):
            if target_children and target_children[-1]["type"] == "list":
                target_children[-1]["inputs"]["items"].append(node)
            else:
                target_children.append({"type": "list", "inputs": {"items": [node]}})

        index = 0
        while index < len(elements):
            element = elements[index]
            index += 1

            if isinstance(element, Figure):
                if pending_figure is not None:
                    emit(pending_figure, top_level=step is None)
                    pending_figure = None
                # Wait for the step this figure sits beside.
                pending_figure = self.figure(element.image)
                continue

            if isinstance(element, Table):
                emit(element.node)
                holder = last_item = None
                continue

            if isinstance(element, Icon):
                # The label is the bold line beside the icon.
                label_line = elements[index] if index < len(elements) and isinstance(elements[index], VLine) else None
                label = label_line.text.strip() if label_line is not None and label_line.bold else ""
                if label.upper().rstrip("!") not in LEVELS:
                    self.flags[f"icon without a known label: {label[:20]!r}"] += 1
                    continue
                index += 1
                self.counts["notes" if element.kind == "note" else "warnings"] += 1
                holder = {"type": "warning", "inputs": {"category": LEVELS[label.upper().rstrip("!")], "children": []},
                          "_label": label, "_box": element.box, "_kind": element.kind}
                last_item = None
                emit(holder)
                continue

            line: VLine = element
            first = line.runs[0].text
            marker = first[:1] if first[:1] in MARKERS else ""
            heading = line.size >= 13 and line.bold

            # Leaving a note or warning: a warning is its box; a note runs while the text stays italic.
            if holder is not None and holder["type"] == "warning":
                if holder["_kind"] == "warning":
                    if line.box is None or line.box != holder["_box"]:
                        holder = None
                elif not line.italic or heading:
                    holder = None

            # Gather the paragraph: following lines that continue this one.
            group = [line]
            indent = None
            while index < len(elements) and isinstance(elements[index], VLine):
                nxt: VLine = elements[index]
                same_page = nxt.page is line.page
                gap = group[-1].y - nxt.y if same_page else 0
                starts = nxt.runs[0].text[:1] in MARKERS
                if starts or not same_page or gap > (line.size + 4 if heading else 13.5) or gap < 0:
                    break
                if heading != (nxt.size >= 13 and nxt.bold) or nxt.box != line.box:
                    break
                if not heading:
                    if nxt.bold != line.bold or (re.match(r"^\d+ -(\t| )", nxt.text) and nxt.nx < 3):
                        break
                    if indent is None:
                        # A continuation sits under the text, not under the marker.
                        expected = line.nx + 14.2 if marker or re.match(r"^\d+ -\t", line.text) else line.nx
                        if abs(nxt.nx - expected) > 3 and not (marker and nxt.nx > line.nx + 5):
                            if not (not marker and abs(nxt.nx - line.nx) < 3):
                                break
                        indent = nxt.nx
                    elif abs(nxt.nx - indent) > 3:
                        break
                group.append(nxt)
                index += 1

            if heading:
                close()
                text = self.markup(group, plain_style=True)
                # (the gap between a heading's number and its title isn't always a tab)
                text = re.sub(r"^(\d+(?:\.\d+)*)(?=[^\d\s.])", r"\1 ", text)
                level = 2 if line.size >= 14 else 3
                anchor = f"section-{len(self.toc) + 1}"
                plain = html.unescape(re.sub(r"<[^>]+>", "", text))
                if not self.title:
                    self.title = plain
                self.toc.append({"label": plain, "anchor": anchor})
                self.anchors.append((line.page.number + 1, (line.page.height - line.top) / line.page.height, anchor))
                self.counts["headings"] += 1
                emit({"type": "static", "inputs": {"html": f'<h{level} id="{anchor}">{text}</h{level}>', "para": False},
                      "_at": [line.page.number + 1, round((line.page.height - line.top) / line.page.height, 4)]},
                     top_level=True)
                continue

            in_holder = holder is not None and holder["type"] == "warning"
            node = self.static(group, para=not marker, plain_style=in_holder)
            if node is None:
                continue

            if in_holder:
                if marker:
                    bullets(holder["inputs"]["children"], node)
                else:
                    holder["inputs"]["children"].append(node)
                continue

            if marker == "–":
                self.counts["steps"] += 1
                holder = last_item = None
                step = {"position": None, "children": []}
                if pending_figure is not None:
                    step["children"].append(pending_figure)
                    pending_figure = None
                step["children"].append(node)
                if content and content[-1]["type"] == "plot" and content[-1].get("_open"):
                    content[-1]["inputs"].append(step)
                else:
                    for block in content:
                        block.pop("_open", None)
                    content.append({"type": "plot", "inputs": [step], "_open": True})
                continue

            if marker in ("•", "♦", "❑"):
                self.counts["bullets"] += 1
                if holder is not None and holder["type"] == "legend":
                    bullets(holder["children"], node)
                elif step is not None:
                    bullets(step["children"], node)
                else:
                    if pending_figure is not None:
                        content.append(pending_figure)
                        pending_figure = None
                    bullets(content, node)
                continue

            legend = re.match(r"^\d+ -(\t| )", line.text) and line.nx < 3
            if legend:
                # "1 - Part name" under an exploded view, with its notes beneath.
                self.counts["legend_entries"] += 1
                step = None
                for block in content:
                    block.pop("_open", None)
                node["inputs"]["para"] = True
                emit(node, top_level=True)
                holder = {"type": "legend", "children": content}
                continue

            if line.bold and not line.red and line.nx < 3 and len(group) <= 2 and line.size == 10 and line.box is None:
                # A bold line on its own: a sub-heading ("Removing", "Installing").
                close()
                for block in content:
                    block.pop("_open", None)
                text = self.markup(group, plain_style=True)
                self.counts["subheadings"] += 1
                emit({"type": "static", "inputs": {"html": f"<h4>{text}</h4>", "para": False}}, top_level=True)
                continue

            # An ordinary paragraph. Indented under a step it belongs to the step.
            if step is not None and line.nx < 3:
                step = None
                for block in content:
                    block.pop("_open", None)
            holder = last_item = None
            emit(node)

        if pending_figure is not None:
            content.append(pending_figure)
        self.number(content)
        # One step per block: the app follows the reading position block by block,
        # which is what lets it keep each step's figure beside the step being read.
        content = [piece for block in content for piece in (
            [{"type": "plot", "inputs": [item]} for item in block["inputs"]] if block["type"] == "plot" else [block])]
        # Where each block was printed (page, fraction from the top), so a link to
        # a spot inside a section can land on the block there.
        def printed_at(value):
            if isinstance(value, dict):
                if "_at" in value:
                    return value["_at"]
                for item in value.values():
                    found = printed_at(item)
                    if found:
                        return found
            elif isinstance(value, list):
                for item in value:
                    found = printed_at(item)
                    if found:
                        return found
            return None
        positions = [printed_at(block) for block in content]
        return {"title": self.title, "content": content, "toc": self.toc, "positions": positions}

    def number(self, blocks: list):
        count = 0
        for block in blocks:
            block.pop("_open", None)
            if block["type"] == "static" and re.match(r"<h[23]", block["inputs"]["html"]):
                count = 0
            elif block["type"] == "plot":
                for item in block["inputs"]:
                    count += 1
                    item["position"] = str(count)


# ---- checking -------------------------------------------------------------------

def texts(value, out: list):
    """All text in a converted document, in order, markup removed."""
    if isinstance(value, str):
        out.append(html.unescape(re.sub(r"<[^>]+>", "", value)))
    elif isinstance(value, list):
        for item in value:
            texts(item, out)
    elif isinstance(value, dict):
        kind, inputs = value.get("type"), value.get("inputs")
        if kind == "static":
            texts(inputs.get("html", ""), out)
        elif kind == "table":
            texts(inputs.get("header", []), out)
            texts(inputs.get("data", []), out)
        elif kind == "plot":
            for item in inputs:
                texts(item.get("children", []), out)
        elif kind == "list":
            texts(inputs.get("items", []), out)
        elif kind == "warning":
            out.append(value.get("_label", ""))      # the label printed beside the icon
            texts(inputs.get("children", []), out)


def dehyphenated(lines: list[str]) -> str:
    """Body text with nothing but white space and line-end soft hyphens removed."""
    out = []
    for line in lines:
        line = line.replace(TAB, " ").strip()
        if line[:1] in MARKERS:
            line = line[1:]
        out.append(squeeze(line[:-1] if line.endswith(SOFT_HYPHEN) else line))
    return "".join(out)


def strip_private(value):
    if isinstance(value, dict):
        for key in [k for k in value if k.startswith("_")]:
            del value[key]
        for item in value.values():
            strip_private(item)
    elif isinstance(value, list):
        for item in value:
            strip_private(item)


def check(path: str, converter: Converter, document: dict) -> dict:
    produced: list[str] = []
    texts(document["content"], produced)
    produced_text = squeeze("".join(produced)).replace(SOFT_HYPHEN, "")
    source_text = dehyphenated(converter.source).replace(SOFT_HYPHEN, "")
    missing = added = 0
    samples = []
    table_moved = False
    if source_text != produced_text:
        # Some pages draw a table before the text above it. Then the order check
        # is made without the tables, and the tables are compared one by one.
        skip = {i for a, b in converter.source_flow_skip for i in range(a, b)}
        flow = dehyphenated([t for i, t in enumerate(converter.source) if i not in skip]).replace(SOFT_HYPHEN, "")
        out_flow: list[str] = []
        out_tables: list[str] = []

        def split(value):
            if isinstance(value, list):
                for item in value:
                    split(item)
            elif isinstance(value, dict) and value.get("type") == "table":
                parts: list[str] = []
                texts(value, parts)
                out_tables.append(squeeze("".join(parts)).replace(SOFT_HYPHEN, ""))
            elif isinstance(value, dict) and value.get("type") == "plot":
                for item in value["inputs"]:
                    split(item.get("children", []))
            elif isinstance(value, dict) and value.get("type") == "warning":
                out_flow.append(value.get("_label", ""))
                split(value["inputs"].get("children", []))
            elif isinstance(value, dict) and value.get("type") == "list":
                split(value["inputs"].get("items", []))
            else:
                texts(value, out_flow)
        split(document["content"])
        if (squeeze("".join(out_flow)).replace(SOFT_HYPHEN, "") == flow
                and sorted(out_tables) == sorted(t.replace(SOFT_HYPHEN, "") for t in converter.source_tables)):
            table_moved = True
    if source_text != produced_text and not table_moved:
        # Trim what matches at both ends, then compare what's left (comparing two
        # long, very different texts character by character takes for ever).
        head = 0
        limit = min(len(source_text), len(produced_text))
        while head < limit and source_text[head] == produced_text[head]:
            head += 1
        tail = 0
        while tail < limit - head and source_text[-1 - tail] == produced_text[-1 - tail]:
            tail += 1
        a, b = source_text[head:len(source_text) - tail], produced_text[head:len(produced_text) - tail]
        if len(a) > 6000 or len(b) > 6000:
            missing, added = len(a), len(b)
            samples.append({"pdf": a[:120], "output": b[:120]})
        else:
            for op, a1, a2, b1, b2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
                if op == "equal":
                    continue
                missing += a2 - a1
                added += b2 - b1
                if len(samples) < 6:
                    samples.append({"pdf": a[max(0, a1 - 25):a2 + 25], "output": b[max(0, b1 - 25):b2 + 25]})

    # Against an independent reader: every number in the page bodies.
    # (cropped to the body: the running header and footer carry numbers of their own)
    raw = subprocess.run(["pdftotext", "-layout", "-x", "0", "-y", "62", "-W", "596", "-H", "728", path, "-"],
                         capture_output=True, text=True).stdout
    independent = re.sub(SOFT_HYPHEN + r"\s*\n\s*", "", raw)
    want = collections.Counter(NUMBER.findall(independent))
    got = collections.Counter(NUMBER.findall(re.sub(SOFT_HYPHEN + r"\s*", "", " ".join(produced))))
    number_missing = {k: v - got.get(k, 0) for k, v in want.items() if v > got.get(k, 0)}
    number_extra = {k: v - want.get(k, 0) for k, v in got.items() if v > want.get(k, 0)}
    return {
        "characters": len(source_text), "characters_missing": missing, "characters_added": added,
        "character_diffs": samples, "numbers": sum(want.values()),
        "numbers_missing": number_missing, "numbers_extra": number_extra,
    }


def convert(entry: dict, split_dir: str, out_dir: str) -> dict:
    path = os.path.join(split_dir, entry["pdf"])
    pages, _ = read(path)
    converter = Converter(pages)
    document = converter.document()
    report = check(path, converter, document)
    report.update({"file": entry["pdf"], "hkap_id": entry["hkap_id"], "pages": len(pages),
                   "group": entry["vehicle_component"], "chapter": entry["title"],
                   "manual": os.path.splitext(entry.get("source", ""))[0].replace("_", " "),
                   "counts": dict(converter.counts), "flags": dict(converter.flags),
                   "anchors": converter.anchors})
    images = {}
    for key, image in converter.media.items():
        extension = save_image(image, os.path.join(out_dir, "media", key))
        if extension:
            images[key] = f"media/{key}{extension}"
        else:
            report["flags"][f"image not saved {key}"] = 1
    produced: list[str] = []
    texts(document["content"], produced)
    unreadable = len(re.findall(r"[\x00-\x08\x0b-\x1f�]", "".join(produced)))
    if unreadable:
        report["flags"]["unreadable characters"] = unreadable
    blocking = {k: v for k, v in report["flags"].items() if not k.startswith("red text without a link")}
    report["passed"] = not (report["characters_missing"] or report["characters_added"] or report["numbers_missing"]
                            or report["numbers_extra"] or blocking or not document["content"])
    strip_private(document)
    document.update({
        "passed": report["passed"], "images": images,
        "text": re.sub(r"[ \t]+", " ", "\n".join(t.strip() for t in produced if t.strip())),
    })
    # Every link with the words it is printed as, for auditing where links land.
    report["links"] = re.findall(r'<a class=\\"qv qv-doc\\" href=\\"([^"\\]+)\\">(.*?)</a>', json.dumps(document["content"], ensure_ascii=False))
    report["arrows"] = re.findall(r'⇒(?![^<]{0,3}(?:“|page))[^<⇒]{3,160}', re.sub(r'<a .*?</a>', '', json.dumps(document["content"], ensure_ascii=False)))
    if report["passed"]:
        parts, targets, named = split_sections(entry["hkap_id"], entry, document, converter.anchors)
    else:
        parts, targets, named = [dict(document, hkap_id=entry["hkap_id"], title=entry["title"],
                                      index=entry["node_value"])], [], []
    for part in parts:
        with open(os.path.join(out_dir, part["hkap_id"] + ".json"), "w") as handle:
            json.dump(part, handle, indent=1, ensure_ascii=False)
    report["parts"] = [{"hkap_id": p["hkap_id"], "title": p["title"], "index": p["index"]} for p in parts]
    report["targets"] = targets
    report["named"] = named
    return report


HEADING = re.compile(r'^<h([23]) id="([^"]+)">(.*)</h[23]>$', re.S)


def split_sections(hkap: str, entry: dict, document: dict, anchors: list[tuple]) -> tuple[list[dict], list[tuple], list]:
    """A chapter as one document per section, the way the Porsche and Ferrari
    manuals are organised: every numbered section that holds something of its
    own (a procedure, an exploded view, a table) becomes a document titled with
    its heading. A section that only lists its sub-sections is navigation, which
    the document list now does, so it gets no document.

    Returns the parts; for each heading's place on the page, where a link to it
    should go; and the same for each heading's title."""
    content = document["content"]
    heads = [(i, HEADING.match(b["inputs"]["html"])) for i, b in enumerate(content) if b["type"] == "static"]
    heads = [(i, m) for i, m in heads if m]
    numbered = [(i, m) for i, m in heads if re.match(r"\d", re.sub(r"<[^>]+>", "", m.group(3)))]
    minor: dict[str, str] = {}      # an unnumbered heading ("Coupé", "R8 Spyder") -> the section it sits in
    if len(numbered) >= 2:
        # Unnumbered headings are variants within a numbered section, not sections.
        current = None
        for i, m in heads:
            if (i, m) in numbered:
                current = m.group(2)
            elif current:
                minor[m.group(2)] = current
                content[i] = {"type": "static", "inputs": {"html": f"<h4>{m.group(3)}</h4>", "para": False}}
        heads = [(i, m) for i, m in heads if m.group(2) not in minor]
    if len(heads) < 2:
        part = dict(document, hkap_id=hkap, title=entry["title"], index=entry["node_value"])
        named = [(entry["title"], hkap)] + [(re.sub(r"<[^>]+>", "", m.group(3)), hkap) for _, m in heads]
        return [part], [(page, frac, hkap) for page, frac, _ in anchors], named
    positions = document["positions"]

    def plain(markup: str) -> str:
        return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", markup))).strip()

    def navigation(block: dict) -> bool:
        return block["type"] == "static" and plain(block["inputs"]["html"]).startswith("⇒")

    parts: list[dict] = []
    owner: dict[str, str | None] = {}         # heading anchor -> the part that starts there
    for n, (start, match) in enumerate(heads):
        end = heads[n + 1][0] if n + 1 < len(heads) else len(content)
        body = content[start + 1:end]
        anchor = match.group(2)
        if not [b for b in body if not navigation(b)]:
            owner[anchor] = None
            continue
        sub = f"{hkap}-{len(parts) + 1:03d}"
        owner[anchor] = sub
        # Sub-headings ("Removing", "Installing") become the document's contents list.
        toc, blocks = [], []
        for block in body:
            heading = block["type"] == "static" and re.match(r"^<h4>(.*)</h4>$", block["inputs"]["html"], re.S)
            if heading:
                mark = f"part-{len(toc) + 1}"
                toc.append({"label": plain(heading.group(1)), "anchor": mark})
                block = {"type": "static", "inputs": {"html": f'<h4 id="{mark}">{heading.group(1)}</h4>', "para": False}}
            blocks.append(block)
        dumped = json.dumps(blocks)
        keys = set(re.findall(r'"key": "(\d+)"', dumped))
        produced: list[str] = []
        texts(blocks, produced)
        heading = plain(match.group(3))
        # The section number is the document's code, as the chapter's is the
        # folder's ("72.2 Front seats" holds "72.2.6.1 Removing and installing
        # front seat ..."); the title is the heading without it.
        number = re.match(r"(\d+(?:\.\d+)*)\s+(.*)$", heading, re.S)
        title = number.group(2) if number else heading
        parts.append({
            "hkap_id": sub, "title": title,
            "index": section_code(entry["node_value"], number.group(1) if number else None, len(parts) + 1),
            "passed": True, "content": blocks, "toc": toc, "positions": positions[start + 1:end],
            "images": {k: v for k, v in document["images"].items() if k in keys},
            "text": heading + "\n" + re.sub(r"[ \t]+", " ", "\n".join(t.strip() for t in produced if t.strip())),
        })
    if not parts:
        # Nothing but pointers elsewhere: keep the chapter as the one document it is.
        part = dict(document, hkap_id=hkap, title=entry["title"], index=entry["node_value"])
        named = [(entry["title"], hkap)] + [(plain(m.group(3)), hkap) for _, m in heads]
        return [part], [(page, frac, hkap) for page, frac, _ in anchors], named
    # A heading with no document of its own leads to the first one under it.
    order = [m.group(2) for _, m in heads]
    targets = []
    for page, frac, anchor in anchors:
        anchor = minor.get(anchor, anchor)
        at = order.index(anchor) if anchor in order else 0
        dest = next((owner[a] for a in order[at:] if owner.get(a)), None) or next(
            (owner[a] for a in reversed(order[:at]) if owner.get(a)), None)
        if dest:
            targets.append((page, frac, dest))
    # ...and by title, for references that name a section in words.
    named = []
    for at, (_, match) in enumerate(heads):
        dest = next((owner[a] for a in order[at:] if owner.get(a)), None)
        if dest:
            named.append((plain(match.group(3)), dest))
    return parts, targets, named


def section_code(node_value: str, number: str | None, part: int) -> str:
    """A section's code: its number in the manual, under its repair group.
    Chapter "72.2" (repair group 72, chapter 2) holds sections 2.1, 2.6.1, ...,
    which become 72.2.1 and 72.2.6.1. A manual without repair groups (chapter
    "3") keeps the bare section number, 3.8."""
    pieces = node_value.split(".")
    if number and number.split(".")[0] == pieces[-1]:
        return ".".join(pieces[:-1] + [number])
    if number and not node_value.strip():
        return number
    # The numbering doesn't follow the chapter's: fall back to its place in it.
    return f"{node_value}.{part}" if node_value.strip() else str(part)


PAGE_LINK = re.compile(r'href="/documents/\d+/[^/]+/([\w-]+)#page=(\d+)(?:&(?:amp;)?y=([\d.]+))?">(.*?)</a>', re.S)
# "⇒ Electrical system; Rep. gr. 27 ; Battery; Disconnecting and connecting battery ."
# "⇒ Maintenance ; Booklet 421 ; Maintenance work; Brake pads: checking thickness ."
TEXT_REF = re.compile(
    r'⇒\s*(?:(?P<manual>[^;⇒<>]{3,90}?)\s*;\s*)?(?:Rep\. gr\.|Booklet)\s*(?P<group>\d+)\s*;\s*(?P<chapter>[^;⇒<>]+?)'
    r'(?:\s*;\s*(?P<section>[^;⇒<>]+?))?(?=\s+\.(?:\s|$|<)|\s*$|\s*<|\s*⇒)')


def norm(title: str) -> str:
    title = html.unescape(re.sub(r"<[^>]+>", "", title))
    title = re.sub(r"^[\d.]+\s+", "", title.strip())
    return re.sub(r"[\s‐-]+", " ", title).strip(" .").lower()


def resolve_links(out_dir: str, reports: list[dict]) -> dict:
    """Make the manual's cross-references land where they point.

    Printed links arrive as "<chapter>#page=N&y=F", a spot on a PDF page. Each
    goes to the document that holds that spot; when the spot is not the start
    of the document, the block printed there gets an anchor and the link aims
    at it.

    References written out in words ("⇒ Rep. gr. 27 ; Battery; Charging
    battery") aren't links in the PDF at all. Those are matched to a document
    by repair group and title and made into links; any that match nothing stay
    as text."""
    good = [r for r in reports if r.get("passed")]
    targets = {r["hkap_id"]: sorted(tuple(t) for t in r["targets"]) for r in good}
    parts = {p["hkap_id"]: json.load(open(os.path.join(out_dir, p["hkap_id"] + ".json")))
             for r in good for p in r["parts"]}
    stats = collections.Counter()
    unresolved = collections.Counter()

    # Titles, for the references in words.
    by_section: dict[tuple, list[str]] = collections.defaultdict(list)
    by_chapter: dict[tuple, list[str]] = collections.defaultdict(list)
    chapter_of: dict[str, tuple] = {}
    def chapter_names(title: str) -> set[str]:
        # r8_split.py tells same-named chapters apart with the manual in brackets.
        return {norm(title), norm(re.sub(r"\s*\([^()]*\)\s*$", "", title))}

    for r in good:
        for title, dest in r["named"]:
            if dest not in by_section[(r["group"], norm(title))]:
                by_section[(r["group"], norm(title))].append(dest)
        for p in r["parts"]:
            for name in chapter_names(r["chapter"]):
                by_chapter[(r["group"], name)].append(p["hkap_id"])
            chapter_of[p["hkap_id"]] = (chapter_names(r["chapter"]), norm(r["manual"]))

    wanted: dict[str, set[int]] = collections.defaultdict(set)     # part -> blocks that need an anchor

    # Section number -> document, per chapter, for links that name their section.
    numbered = {r["hkap_id"]: {m.group(0): dest for title, dest in r["named"]
                               if (m := re.match(r"\d+(?:\.\d+)*", title))} for r in good}

    def page_link(match: re.Match) -> str:
        hkap, page, frac = match.group(1), int(match.group(2)), float(match.group(3) or 0)
        tail = f'">{match.group(4)}</a>'
        known = targets.get(hkap)
        if not known:
            stats["left as page references"] += 1
            return match.group(0)
        # A link that names its section ("2.3 Checking alternator", page 12) goes
        # to that section: the spot on the page can sit a line above the heading.
        quoted = re.search(r"“(\d+(?:\.\d+)*)\s", re.sub(r"<[^>]+>", "", match.group(4)))
        if quoted and quoted.group(1) in numbered.get(hkap, {}):
            stats["to the start of a document"] += 1
            return f'href="/documents/{YEAR}/{MODEL}/{numbered[hkap][quoted.group(1)]}{tail}'
        # (headings can sit two lines apart, so the allowance is under a line)
        at_or_before = [a for a in known if (a[0], a[1]) <= (page, frac + 0.006)]
        target = at_or_before[-1] if at_or_before else known[0]
        dest = target[2]
        if target[0] == page and abs(target[1] - frac) < 0.006:
            stats["to the start of a document"] += 1
            return f'href="/documents/{YEAR}/{MODEL}/{dest}{tail}'
        # Somewhere inside the document: the last block printed at or above the spot.
        positions = parts[dest].get("positions") or []
        block = max((i for i, at in enumerate(positions) if at and (at[0], at[1]) <= (page, frac + 0.006)), default=None)
        if not block:
            stats["to the start of a document"] += 1
            return f'href="/documents/{YEAR}/{MODEL}/{dest}{tail}'
        wanted[dest].add(block)
        stats["to a place inside a document"] += 1
        return f'href="/documents/{YEAR}/{MODEL}/{dest}#ref-{block}{tail}'

    def text_ref(source: str):
        def swap(match: re.Match) -> str:
            group = f"{int(match.group('group')):02d}" if len(match.group('group')) < 2 else match.group('group')
            whole, rest = match.group(0), ""
            # The general manuals point into "the vehicle-specific Workshop Manual":
            # the reference ends at that bracket, whatever the sentence goes on to say.
            generic = re.search(r"\(vehicle-\s*specific Workshop Manual\)", whole)
            chapter_text = match.group("chapter")
            if generic:
                whole, rest = whole[:generic.end()], whole[generic.end():]
                chapter_text = re.sub(r"\s*\(vehicle-\s*specific Workshop Manual\).*$", "", chapter_text, flags=re.S)
            chapter, section = norm(chapter_text), norm(match.group("section") or "")
            if generic and match.group("section") and generic.start() < match.start("section") - match.start():
                section = ""
            section = norm(re.sub(r"\s*\(vehicle-\s*specific Workshop Manual\).*$", "", match.group("section") or "", flags=re.S)) if section else ""
            manual = norm(match.group("manual") or "")
            found = by_section.get((group, section), []) if section else []
            if len(found) > 1:
                narrowed = [h for h in found if chapter in chapter_of[h][0]] or found
                narrowed = [h for h in narrowed if not manual or chapter_of[h][1].startswith(manual[:12])] or narrowed
                found = narrowed
            if not found:
                found = by_chapter.get((group, chapter), [])
                if not found:
                    found = by_section.get((group, chapter), [])
                if len(found) > 1 and manual:
                    found = [h for h in found if chapter_of[h][1].startswith(manual[:12])] or found
            if not found or found[0] == source:
                known_group = any(key[0] == group for key in by_chapter)
                stats["references in words left as text"
                      + ("" if known_group else " (to a manual that isn't in this set)")] += 1
                if known_group:
                    unresolved[(group, chapter, section)] += 1
                return match.group(0)
            stats["references in words made links"] += 1
            return f'<a class="qv qv-doc" href="/documents/{YEAR}/{MODEL}/{found[0]}">{whole}</a>{rest}'
        return swap

    def walk(value, source: str):
        if isinstance(value, dict):
            if value.get("type") == "static":
                markup = PAGE_LINK.sub(page_link, value["inputs"]["html"])
                # (only outside existing links)
                pieces = re.split(r"(<a .*?</a>)", markup)
                value["inputs"]["html"] = "".join(
                    piece if piece.startswith("<a ") else TEXT_REF.sub(text_ref(source), piece) for piece in pieces)
            for item in value.values():
                walk(item, source)
        elif isinstance(value, list):
            for item in value:
                walk(item, source)

    for name, document in parts.items():
        walk(document["content"], name)
    for name, document in parts.items():
        # Anchors where links land inside the document. A step carries its own id;
        # anything else gets an anchor placed before it (from the end, so the
        # block numbers still hold).
        for block in sorted(wanted.get(name, ()), reverse=True):
            target = document["content"][block]
            if target["type"] == "plot":
                target["inputs"][0]["id"] = f"ref-{block}"
            else:
                document["content"].insert(block, {"type": "anchor", "inputs": {"id": f"ref-{block}"}})
        document.pop("positions", None)
        with open(os.path.join(out_dir, name + ".json"), "w") as handle:
            json.dump(document, handle, indent=1, ensure_ascii=False)
    with open(os.path.join(out_dir, "unresolved-references.json"), "w") as handle:
        json.dump([{"group": g, "chapter": c, "section": sec, "count": n} for (g, c, sec), n in unresolved.most_common()],
                  handle, indent=1, ensure_ascii=False)
    return dict(stats)


def _worker(args):
    entry = args[0]
    try:
        return convert(*args)
    except Exception as error:      # reported, not hidden
        import traceback
        return {"file": entry["pdf"], "hkap_id": entry["hkap_id"], "passed": False, "parts": [], "targets": [], "named": [],
                "error": f"{type(error).__name__}: {error}", "trace": traceback.format_exc()[-600:]}


if __name__ == "__main__":
    import logging
    import multiprocessing
    import shutil
    logging.disable(logging.WARNING)
    split_dir, out_dir = sys.argv[1], sys.argv[2]
    only = sys.argv[3:]
    manifest = json.load(open(os.path.join(split_dir, "manifest.json")))
    entries = [d for d in manifest["documents"] if not only or any(o in d["pdf"] for o in only)]
    if not only:
        shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(os.path.join(out_dir, "media"), exist_ok=True)
    with multiprocessing.Pool() as pool:
        reports = pool.map(_worker, [(e, split_dir, out_dir) for e in entries])
    with open(os.path.join(out_dir, "report.json"), "w") as handle:
        json.dump(reports, handle, indent=1, ensure_ascii=False)
    link_stats = resolve_links(out_dir, reports)
    # Which documents each chapter became, for the loader.
    with open(os.path.join(out_dir, "index.json"), "w") as handle:
        json.dump({r["hkap_id"]: r["parts"] for r in reports if r.get("passed")}, handle, indent=1, ensure_ascii=False)
    documents = sum(len(r.get("parts", [])) for r in reports if r.get("passed"))
    for r in reports:
        if not r["passed"]:
            why = r.get("error") or (f"chars -{r['characters_missing']} +{r['characters_added']}  "
                                     f"numbers -{sum(r['numbers_missing'].values())} +{sum(r['numbers_extra'].values())}  "
                                     f"flags {list(r['flags'])[:2]}")
            print(f"pdf   {r['file'][-62:]:62} {why}")
    passed = sum(1 for r in reports if r["passed"])
    print(f"{passed} of {len(reports)} chapters structured, as {documents} documents; {len(reports) - passed} stay PDF")
    print("links: " + "; ".join(f"{v} {k}" for k, v in sorted(link_stats.items())))
