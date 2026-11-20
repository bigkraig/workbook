"""Read a tagged Ferrari techdoc PDF (a Chrome print of the techdoc site) back
into the DOM it was printed from.

Chrome writes a structure tree that mirrors the page's HTML (P, Table/TR/TD,
Figure, Link, and NonStruct for div/span), with every piece of text and every
image tied to its element by a marked-content id. Walking that tree gives the
document's structure without guessing from positions on the page.

    Node(tag, attrs, children)   an element
    Text(text, bold, color)      a run of text
    Image(objid, w, h, ...)      a drawn image (w/h in page points)
    Target(uri)                  the destination of the enclosing Link
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field

from pdfminer.pdfdevice import PDFDevice
from pdfminer.pdfdocument import PDFDocument
from pdfminer.pdfinterp import PDFPageInterpreter, PDFResourceManager
from pdfminer.pdfpage import PDFPage
from pdfminer.pdfparser import PDFParser
from pdfminer.pdftypes import PDFObjRef, PDFStream, resolve1
from pdfminer.psparser import PSLiteral
from pdfminer.utils import mult_matrix


@dataclass
class Text:
    text: str
    bold: bool = False
    color: tuple = ()
    wrapped: bool = False   # starts a new printed line (the wrap ate a space)


@dataclass
class Image:
    objid: int
    width: float          # as drawn, in points
    height: float
    px: tuple             # pixel size of the embedded image
    sha: str              # of the raw stream, to recognise repeated icons
    stream: PDFStream = field(repr=False, default=None)


@dataclass
class Target:
    uri: str


@dataclass
class Node:
    tag: str
    attrs: dict = field(default_factory=dict)
    children: list = field(default_factory=list)

    def text(self) -> str:
        out = []
        for child in self.children:
            if isinstance(child, Text):
                out.append(child.text)
            elif isinstance(child, Node):
                out.append(child.text())
        return "".join(out)

    def walk(self):
        yield self
        for child in self.children:
            if isinstance(child, Node):
                yield from child.walk()


def _name(value) -> str:
    value = resolve1(value)
    return value.name if isinstance(value, PSLiteral) else str(value)


class _Collector(PDFDevice):
    """Collects each marked-content sequence's text runs and images."""

    def __init__(self, rsrcmgr):
        super().__init__(rsrcmgr)
        self.content: dict[int, list] = {}
        self.position: dict[int, tuple] = {}   # where each sequence starts on the page
        self.all_text: list[str] = []     # everything drawn, tagged or not
        self._stack: list[int | None] = []
        self._last_y = None

    def begin_tag(self, tag, props=None):
        mcid = None
        props = resolve1(props) if props is not None else None
        if isinstance(props, dict) and "MCID" in props:
            mcid = props["MCID"]
        self._stack.append(mcid)

    def end_tag(self):
        if self._stack:
            self._stack.pop()

    def _current(self, at=None):
        for mcid in reversed(self._stack):
            if mcid is not None:
                if at is not None:
                    self.position.setdefault(mcid, (round(at[0]), round(at[1])))
                return self.content.setdefault(mcid, [])
        return None

    def render_string(self, textstate, seq, ncs, graphicstate):
        font = textstate.font
        chars = []
        for obj in seq:
            if isinstance(obj, bytes):
                for cid in font.decode(obj):
                    try:
                        chars.append(font.to_unichr(cid))
                    except Exception:
                        chars.append("�")
        text = "".join(chars)
        if not text:
            return
        self.all_text.append(text)
        # A line wrap swallows the space between two words; note where lines
        # start so it can be put back.
        placed = mult_matrix(textstate.matrix, self.ctm)
        y = placed[5]
        wrapped = self._last_y is not None and abs(y - self._last_y) > 0.7 * (textstate.fontsize or 10)
        self._last_y = y
        bucket = self._current(placed[4:6])
        if bucket is None:
            return
        color = graphicstate.ncolor
        color = tuple(round(c, 2) for c in color) if isinstance(color, (tuple, list)) else (round(color or 0, 2),)
        bold = "Bold" in (font.fontname or "")
        last = bucket[-1] if bucket else None
        if isinstance(last, Text) and last.bold == bold and last.color == color:
            if wrapped and not last.text[-1:].isspace() and not text[:1].isspace():
                last.text += " "
            last.text += text
        else:
            bucket.append(Text(text, bold, color, wrapped))

    def render_image(self, name, stream):
        bucket = self._current(self.ctm[4:6])
        if bucket is None:
            return
        a, b, c, d, _, _ = self.ctm
        raw = stream.get_rawdata() or b""
        bucket.append(Image(
            objid=stream.objid,
            width=round((a * a + b * b) ** 0.5, 1),
            height=round((c * c + d * d) ** 0.5, 1),
            px=(stream.get("Width"), stream.get("Height")),
            sha=hashlib.sha1(raw).hexdigest()[:12],
            stream=stream,
        ))


class Dom:
    def __init__(self, path: str):
        self.path = path
        with open(path, "rb") as handle:
            self._load(handle)

    def _load(self, handle):
        doc = PDFDocument(PDFParser(handle))
        rsrcmgr = PDFResourceManager()
        self.pages: dict[int, _Collector] = {}
        self.page_count = 0
        self.all_text: list[str] = []
        for page in PDFPage.create_pages(doc):
            device = _Collector(rsrcmgr)
            PDFPageInterpreter(rsrcmgr, device).process_page(page)
            self.pages[page.pageid] = device
            self.all_text.extend(device.all_text)
            self.page_count += 1
        root = resolve1(doc.catalog.get("StructTreeRoot"))
        if not root:
            raise ValueError("not a tagged PDF")
        self.repeats: list[str] = []      # reprinted on a later page, dropped
        self.overprints: list[str] = []   # painted twice in one spot, dropped
        self.root = Node("Root")
        self._kids(root.get("K"), None, self.root)

    def _kids(self, kids, page, parent: Node):
        kids = resolve1(kids)
        if kids is None:
            return
        if not isinstance(kids, list):
            kids = [kids]
        # Chrome paints some things more than once: a table header at the top
        # of each page the table runs onto, and a block that straddles a page
        # break (drawn twice in the same spot). Both show up as the same
        # content under one element; keep the first.
        seen: dict[tuple, tuple] = {}
        for kid in kids:
            kid = resolve1(kid)
            if isinstance(kid, int):
                self._content(kid, page, parent, seen)
            elif isinstance(kid, dict):
                kind = _name(kid.get("Type")) if "Type" in kid else ""
                if kind == "MCR":
                    pg = kid.get("Pg")
                    self._content(kid["MCID"], pg.objid if isinstance(pg, PDFObjRef) else page, parent, seen)
                elif kind == "OBJR":
                    obj = resolve1(kid.get("Obj")) or {}
                    action = resolve1(obj.get("A")) or {}
                    uri = resolve1(action.get("URI"))
                    if uri:
                        parent.children.append(Target(uri.decode("latin-1") if isinstance(uri, bytes) else str(uri)))
                else:
                    pg = kid.get("Pg")
                    node = Node(_name(kid.get("S")), self._attrs(kid.get("A")))
                    parent.children.append(node)
                    self._kids(kid.get("K"), pg.objid if isinstance(pg, PDFObjRef) else page, node)

    def _content(self, mcid, page, parent: Node, seen: dict):
        device = self.pages.get(page)
        if device is None:
            return
        items = device.content.get(mcid, [])
        if not items:
            return
        signature = tuple(i.text if isinstance(i, Text) else i.sha for i in items)
        here = (page, device.position.get(mcid))
        first = seen.setdefault(signature, here)
        if first is not here and (first[0] != page or first[1] == here[1]):
            text = "".join(i.text for i in items if isinstance(i, Text))
            (self.repeats if first[0] != page else self.overprints).append(text)
            return
        parent.children.extend(items)

    @staticmethod
    def _attrs(value) -> dict:
        value = resolve1(value)
        out = {}
        for item in value if isinstance(value, list) else [value]:
            item = resolve1(item)
            if isinstance(item, dict):
                for key, val in item.items():
                    val = resolve1(val)
                    if key in ("RowSpan", "ColSpan"):
                        out[key] = int(val)
        return out


def dump(node, depth=0, out=None):
    """Indented text form of the tree, with div/span chains collapsed."""
    out = [] if out is None else out
    pad = "  " * depth
    if isinstance(node, Text):
        out.append(f"{pad}{'B' if node.bold else 'T'}{'~' if node.wrapped else ''}{list(node.color)} {node.text!r}")
    elif isinstance(node, Image):
        out.append(f"{pad}IMG {node.px[0]}x{node.px[1]}px drawn {node.width}x{node.height} {node.sha}")
    elif isinstance(node, Target):
        out.append(f"{pad}-> {node.uri}")
    else:
        while node.tag == "NonStruct" and len(node.children) == 1 and isinstance(node.children[0], Node):
            node = node.children[0]
        out.append(f"{pad}<{node.tag}{' ' + str(node.attrs) if node.attrs else ''}>")
        for child in node.children:
            dump(child, depth + 1, out)
    return out


if __name__ == "__main__":
    import sys
    print("\n".join(dump(Dom(sys.argv[1]).root)))
