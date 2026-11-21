"""Read an Audi R8 workshop-manual PDF (VW/Audi ELSA print layout) as the lines,
images and ruled lines on each page, in the order the page draws them.

These PDFs aren't tagged, but the layout is machine-made and regular: one
typeface, bold drawn as fill-and-stroke, italics as a sheared text matrix,
links in red, list markers (–, •, ♦, ❑) at fixed indents, and a gap inside a
string wherever the original had a tab (between a heading's number and its
title, or a marker and its text).

    Line(y, x, size, runs)       runs: Run(x, text, bold, italic, red)
    Image(x, y, w, h, px, sha)   as drawn, in page points (origin bottom-left)
    Rule(x0, y0, x1, y1)         a stroked straight line
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field

from pdfminer.pdfdevice import PDFDevice
from pdfminer.pdfdocument import PDFDocument
from pdfminer.pdfinterp import PDFPageInterpreter, PDFResourceManager
from pdfminer.pdfpage import PDFPage
from pdfminer.pdfparser import PDFParser
from pdfminer.pdftypes import PDFStream, resolve1
from pdfminer.utils import apply_matrix_pt, mult_matrix

TAB = "\t"


@dataclass
class Run:
    x: float
    text: str
    bold: bool = False
    italic: bool = False
    red: bool = False
    end: float = 0.0      # x where the run stops
    shift: str = ""       # "sup" / "sub": set small and raised or lowered (a fraction, m³, a footnote mark)


@dataclass
class Line:
    y: float
    x: float
    size: float
    runs: list = field(default_factory=list)

    @property
    def text(self) -> str:
        return "".join(r.text for r in self.runs)

    @property
    def bold(self) -> bool:
        shown = [r for r in self.runs if r.text.strip()]
        return bool(shown) and all(r.bold for r in shown)

    @property
    def italic(self) -> bool:
        shown = [r for r in self.runs if r.text.strip()]
        return bool(shown) and all(r.italic for r in shown)


@dataclass
class Image:
    x: float
    y: float
    w: float
    h: float
    px: tuple
    sha: str
    stream: PDFStream = field(repr=False, default=None)


@dataclass
class Rule:
    x0: float
    y0: float
    x1: float
    y1: float
    red: bool = False     # a link's underline

    @property
    def horizontal(self) -> bool:
        return abs(self.y0 - self.y1) < 1 and abs(self.x0 - self.x1) > 2

    @property
    def vertical(self) -> bool:
        return abs(self.x0 - self.x1) < 1 and abs(self.y0 - self.y1) > 2


@dataclass
class Link:
    rect: tuple           # x0, y0, x1, y1
    uri: str = ""         # a cross-document link (rewritten by r8_split.py)
    page: int | None = None   # an in-document link: 0-based page it goes to


class _Collector(PDFDevice):
    def __init__(self, rsrcmgr):
        super().__init__(rsrcmgr)
        self.items: list = []
        self.all_text: list[str] = []

    def render_string(self, textstate, seq, ncs, graphicstate):
        font = textstate.font
        matrix = mult_matrix(textstate.matrix, self.ctm)
        size = round(textstate.fontsize * (matrix[0] ** 2 + matrix[1] ** 2) ** 0.5, 1)
        parts: list[str] = []
        width = 0.0
        for obj in seq:
            if isinstance(obj, bytes):
                for cid in font.decode(obj):
                    try:
                        parts.append(font.to_unichr(cid))
                    except Exception:
                        parts.append("�")
                    width += font.char_width(cid) * size
            elif isinstance(obj, (int, float)):
                # A wide gap inside a string is a tab in the original.
                if obj < -500 and parts and parts[-1] != TAB:
                    parts.append(TAB)
                width -= obj / 1000 * size
        text = "".join(parts)
        if not text:
            return
        self.all_text.append(text)
        color = graphicstate.ncolor
        red = isinstance(color, (tuple, list)) and len(color) == 3 and color[0] > 0.8 and color[1] < 0.2 and color[2] < 0.2
        run = Run(x=round(matrix[4], 1), text=text, bold=textstate.render == 2,
                  italic=abs(matrix[2]) > 0.01, red=red, end=round(matrix[4] + width, 1))
        y = round(matrix[5], 1)
        last = self.items[-1] if self.items else None
        if isinstance(last, Line) and abs(last.y - y) < 1 and abs(last.size - size) < 0.1 and run.x >= last.x:
            last.runs.append(run)
        else:
            self.items.append(Line(y=y, x=run.x, size=size, runs=[run]))

    def render_image(self, name, stream):
        a, b, c, d, e, f = self.ctm
        raw = stream.get_rawdata() or b""
        self.items.append(Image(x=round(e, 1), y=round(f, 1), w=round(abs(a), 1), h=round(abs(d), 1),
                                px=(stream.get("Width"), stream.get("Height")),
                                sha=hashlib.sha1(raw).hexdigest()[:12], stream=stream))

    def paint_path(self, graphicstate, stroke, fill, evenodd, path):
        if not stroke:
            return
        points = [apply_matrix_pt(self.ctm, (p[-2], p[-1])) for p in path if p[0] in ("m", "l")]
        color = graphicstate.scolor
        red = isinstance(color, (tuple, list)) and len(color) == 3 and color[0] > 0.8 and color[1] < 0.2
        for (x0, y0), (x1, y1) in zip(points, points[1:]):
            self.items.append(Rule(round(x0, 1), round(y0, 1), round(x1, 1), round(y1, 1), red))


@dataclass
class Page:
    number: int
    items: list
    links: list
    height: float


def read(path: str) -> tuple[list[Page], list[str]]:
    with open(path, "rb") as handle:
        doc = PDFDocument(PDFParser(handle))
        rsrcmgr = PDFResourceManager()
        pages: list[Page] = []
        all_text: list[str] = []
        raw_pages = list(PDFPage.create_pages(doc))
        index_of = {page.pageid: i for i, page in enumerate(raw_pages)}
        for number, page in enumerate(raw_pages):
            device = _Collector(rsrcmgr)
            PDFPageInterpreter(rsrcmgr, device).process_page(page)
            links = []
            for annot in resolve1(page.annots) or []:
                annot = resolve1(annot)
                if not isinstance(annot, dict) or str(annot.get("Subtype")) != "/'Link'":
                    continue
                rect = tuple(float(v) for v in resolve1(annot.get("Rect")))
                action = resolve1(annot.get("A")) or {}
                uri = resolve1(action.get("URI"))
                link = Link(rect=rect)
                if uri:
                    link.uri = uri.decode("latin-1") if isinstance(uri, bytes) else str(uri)
                else:
                    dest = resolve1(action.get("D")) or resolve1(annot.get("Dest"))
                    if isinstance(dest, list) and dest and hasattr(dest[0], "objid"):
                        link.page = index_of.get(dest[0].objid)
                links.append(link)
            pages.append(Page(number=number, items=device.items, links=links, height=float(page.mediabox[3])))
            all_text.extend(device.all_text)
        return pages, all_text


if __name__ == "__main__":
    import logging
    import sys
    logging.disable(logging.WARNING)
    pages, _ = read(sys.argv[1])
    for page in pages[int(sys.argv[2]):int(sys.argv[2]) + 1] if len(sys.argv) > 2 else pages:
        print(f"--- page {page.number} ({len(page.links)} links)")
        for item in page.items:
            if isinstance(item, Line):
                flags = "".join(f for f, on in (("B", item.bold), ("I", item.italic)) if on)
                print(f"L y={item.y:6} x={item.x:5} s={item.size:4} {flags:2} {item.text!r}")
            elif isinstance(item, Image):
                print(f"I x={item.x} y={item.y} {item.w}x{item.h} px={item.px} {item.sha}")
            else:
                print(f"R {item.x0},{item.y0} -> {item.x1},{item.y1}")
        for link in page.links:
            print("  link", [round(v) for v in link.rect], link.uri[-60:] or link.page)
