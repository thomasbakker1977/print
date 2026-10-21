"""Leest het draaiboek-PDF uit en zet het om naar hoofdstukken, secties en blokken.

Koppen worden herkend aan het vette lettertype: 18 pt = hoofdstuk, 14 pt = sectie
(paragraaf of werkdag), 11 pt = tussenkop binnen een sectie. Tabellen waarvan de
eerste kolom een statussymbool bevat (☐ ◐ ☑ —) worden takenlijsten.
"""

import os
import re

STATUS = {"☐": "open", "◐": "loopt", "☑": "gereed", "—": "nvt"}


def _joinlines(s):
    # pdfplumber geeft afgebroken celtekst met regeleinden terug: weer aan elkaar plakken
    s = re.sub(r"[ \t]+", " ", (s or "").replace("­", "")).strip()
    return re.sub(r"\s*\n\s*", " ", s)


def _inside(obj, bbox):
    x0, top, x1, bottom = bbox
    cx = (obj["x0"] + obj["x1"]) / 2
    cy = (obj["top"] + obj["bottom"]) / 2
    return x0 <= cx <= x1 and top <= cy <= bottom


def _heading_level(line):
    chars = [c for c in line["chars"] if c["text"].strip()]
    if not chars or not all("Bold" in c["fontname"] for c in chars):
        return 0
    size = max(c["size"] for c in chars)
    if size >= 17:
        return 1
    if size >= 13:
        return 2
    if size >= 10.5:
        return 3
    return 0


def parse_pdf(pdf_path, image_dir):
    """Geeft een lijst hoofdstukken terug; afbeeldingen worden in image_dir opgeslagen."""
    import pdfplumber

    os.makedirs(image_dir, exist_ok=True)
    chapters = []
    state = {"chapter": None, "section": None, "group": ""}

    def new_chapter(title):
        state["chapter"] = {"title": title, "sections": []}
        chapters.append(state["chapter"])
        state["section"] = None
        state["group"] = ""

    def section():
        if state["chapter"] is None:
            new_chapter("Inleiding")
        if state["section"] is None:
            state["section"] = {"title": state["chapter"]["title"], "blocks": []}
            state["chapter"]["sections"].append(state["section"])
        return state["section"]

    def add_block(kind, **kw):
        blocks = section()["blocks"]
        last = blocks[-1] if blocks else None
        if last and last["kind"] == kind and last["title"] == state["group"]:
            # Tabellen die over een pagina doorlopen samenvoegen
            if kind == "text":
                last["text"] += "\n" + kw["text"]
                return
            if kind == "tasks" and last["columns"] == kw["columns"]:
                last["tasks"] += kw["tasks"]
                return
            if kind == "table" and last["header"] == kw["header"]:
                last["rows"] += kw["rows"]
                return
        block = {"kind": kind, "title": state["group"]}
        block.update(kw)
        blocks.append(block)

    image_count = 0
    with pdfplumber.open(pdf_path) as pdf:
        for page_no, page in enumerate(pdf.pages, 1):
            items = []
            tables = page.find_tables()
            bboxes = [t.bbox for t in tables]
            for t in tables:
                items.append((t.bbox[1], "table", t.extract()))
            for im in page.images:
                if im["x1"] - im["x0"] < 60 or im["bottom"] - im["top"] < 40:
                    continue
                items.append((im["top"], "image", (im["x0"], im["top"], im["x1"], im["bottom"])))
            for line in page.extract_text_lines(return_chars=True):
                text = line["text"].strip()
                # Paginakop en -voet overslaan
                if line["top"] < 40 or re.match(r"^Pagina \d+ van \d+$", text):
                    continue
                if any(_inside(line, b) for b in bboxes):
                    continue
                level = _heading_level(line)
                items.append((line["top"], "heading" if level else "line", (level, text)))
            items.sort(key=lambda i: i[0])

            for _, kind, data in items:
                if kind == "heading":
                    level, text = data
                    if level == 1:
                        new_chapter(text)
                    elif level == 2:
                        if state["chapter"] is None:
                            new_chapter("Inleiding")
                        state["section"] = {"title": text, "blocks": []}
                        state["chapter"]["sections"].append(state["section"])
                        state["group"] = ""
                    else:
                        state["group"] = text
                elif kind == "line":
                    add_block("text", text=data[1])
                elif kind == "image":
                    image_count += 1
                    name = f"p{page_no:02d}_{image_count:03d}.jpg"
                    x0, top, x1, bottom = data
                    bbox = (max(x0, 0), max(top, 0), min(x1, page.width), min(bottom, page.height))
                    img = page.crop(bbox).to_image(resolution=130).original.convert("RGB")
                    img.save(os.path.join(image_dir, name), quality=80)
                    add_block("image", file=name)
                else:
                    rows = [[_joinlines(c) for c in r] for r in data]
                    if page_no == 1:
                        continue  # legenda van de statussymbolen
                    header = rows[0]
                    if header[0] == "" and len(header) > 2:
                        tasks = []
                        for r in rows[1:]:
                            tasks.append({
                                "status": STATUS.get(r[0].strip(), "open"),
                                "fields": list(zip(header[1:], r[1:])),
                            })
                        add_block("tasks", columns=header[1:], tasks=tasks)
                    elif len(header) == 2:
                        add_block("info", rows=rows)
                    else:
                        add_block("table", header=header, rows=rows[1:])
    return chapters
