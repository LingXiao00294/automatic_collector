"""Original rig and deterministic DST BILD v6 / ANIM v4 exporter.

Raster parts come from the generated sheet; motion is authored here as articulated
transforms. Klei's installed TextureConverter handles BC3 compression. No game or
workshop artwork is copied into the output.
"""

from __future__ import annotations

import argparse
import io
import itertools
import json
import math
import struct
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/source"
WORK = ROOT / "asset_work"
GENERATED = ROOT / "assets/generated"
DEFAULT_TOOLS = Path("D:/Programs/Steam/steamapps/common/Don't Starve Mod Tools/mod_tools")


def name_hash(name: str) -> int:
    value = 0
    for char in name.lower():
        value = (ord(char) + value * 65599) & 0xFFFFFFFF
    return value


def write_string(stream: io.BytesIO, value: str) -> None:
    data = value.encode("ascii")
    stream.write(struct.pack("<I", len(data)) + data)


def write_hashes(stream: io.BytesIO, names: set[str]) -> None:
    stream.write(struct.pack("<I", len(names)))
    for name in sorted(names, key=name_hash):
        stream.write(struct.pack("<I", name_hash(name)))
        write_string(stream, name)


@dataclass
class Sprite:
    name: str
    image: Image.Image
    pivot_x: float
    pivot_y: float
    atlas_x: int = 0
    atlas_y: int = 0

    @property
    def corners(self) -> tuple[float, float, float, float]:
        return (
            -self.pivot_x,
            -self.pivot_y,
            self.image.width - self.pivot_x,
            self.image.height - self.pivot_y,
        )


@dataclass
class Element:
    sprite: str
    layer: str
    x: float
    y: float
    angle: float = 0
    sx: float = 1
    sy: float = 1

    @property
    def matrix(self) -> tuple[float, ...]:
        rad = math.radians(self.angle)
        return (
            math.cos(rad) * self.sx,
            math.sin(rad) * self.sx,
            -math.sin(rad) * self.sy,
            math.cos(rad) * self.sy,
            self.x,
            self.y,
        )


@dataclass
class Animation:
    name: str
    view: str
    facing: int
    frames: list[list[Element]]


def extract_parts(spec: dict) -> dict[str, Sprite]:
    """Load the three authored chassis sprites; discard stale generated parts."""
    parts = {}
    out = GENERATED / "parts"
    out.mkdir(parents=True, exist_ok=True)
    for name, definition in spec["parts"].items():
        image = Image.open(SOURCE / definition["source"]).convert("RGBA")
        if image.getchannel("A").getextrema() != (0, 255):
            raise ValueError(f"Sprite must have transparent and opaque pixels: {name}")
        height = definition["height"]
        image = image.resize(
            (round(image.width * height / image.height), height), Image.Resampling.LANCZOS
        )
        image.save(out / f"{name}.png")
        px, py = definition["pivot"]
        parts[name] = Sprite(name, image, px * image.width, py * image.height)
    for path in out.glob("*.png"):
        if path.stem not in parts and path.resolve().parent == out.resolve():
            path.unlink()
    return parts


def smooth_keys(t: float, keys: list[tuple[float, float]]) -> float:
    for (a, va), (b, vb) in itertools.pairwise(keys):
        if t <= b:
            u = max(0, (t - a) / (b - a))
            u = u * u * (3 - 2 * u)
            return va + (vb - va) * u
    return keys[-1][1]


def pose(name: str, view: str, t: float) -> list[Element]:
    """One chassis only: preserve the ram, sink for pickup, nod for delivery."""
    side = view in ("right", "left")
    mirror = -1 if view == "left" else 1
    sprite_view = "side" if side else "back" if view == "up" else "front"
    bob = math.sin(t * 2 * math.pi) * 0.5
    tilt = 0.0
    travel = 0.0
    squash = 1.0
    if name.startswith("walk"):
        bob = math.sin(t * 4 * math.pi) * 1.3
        tilt = math.sin(t * 2 * math.pi) * 1.2
    elif name == "pickup":
        sink = smooth_keys(t, [(0, 0), (0.3, 0.4), (15 / 29, 1), (0.68, 1), (1, 0)])
        bob = sink * 18
        squash = 1 - sink * 0.12
    elif name == "hammer":
        # Unchanged chassis motion from the approved hammer.gif (contact frame 21).
        travel = smooth_keys(
            t, [(0, 0), (0.35, -18), (0.49, -18), (21 / 38, 32), (0.7, 10), (1, 0)]
        )
        tilt = smooth_keys(t, [(0, 0), (0.35, -4), (21 / 38, 6), (0.7, -2), (1, 0)])
    elif name == "store":
        nod = smooth_keys(t, [(0, 0), (3 / 29, 0.5), (6 / 29, 1), (0.65, 1), (1, 0)])
        bob = nod * 8
        tilt = nod * 5

    dx = travel * mirror if side else 0
    dy = bob + (travel * (0.55 if view == "down" else -0.55) if not side else 0)
    return [
        Element(f"body_{sprite_view}", "body", dx, dy, tilt * mirror if side else 0, mirror, squash)
    ]


def animations(spec: dict) -> list[Animation]:
    result = []
    for name, definition in spec["animations"].items():
        count = definition["frames"]
        # SetFourFaced mirrors the shared side animation for a left facing.
        # Exporting a pre-mirrored left pose would apply the reflection twice.
        for view, facing in [("down", 8), ("right", 5), ("up", 2)]:
            loop = name in ("idle", "walk_loop")
            frames = [pose(name, view, i / (count if loop else count - 1)) for i in range(count)]
            result.append(Animation(name, view, facing, frames))
    return result


def bounds(elements: list[Element], parts: dict[str, Sprite]) -> tuple[float, ...]:
    points = []
    for element in elements:
        a, b, c, d, tx, ty = element.matrix
        left, top, right, bottom = parts[element.sprite].corners
        for x, y in [(left, top), (right, top), (left, bottom), (right, bottom)]:
            points.append((a * x + c * y + tx, b * x + d * y + ty))
    xs, ys = zip(*points)
    x1, y1, x2, y2 = min(xs), min(ys), max(xs), max(ys)
    return (x1 + x2) / 2, (y1 + y2) / 2, x2 - x1, y2 - y1


def pack_atlas(parts: dict[str, Sprite]) -> Image.Image:
    atlas = Image.new("RGBA", (512, 512))
    x, y, row_height = 4, 4, 0
    for sprite in parts.values():
        if x + sprite.image.width + 4 > atlas.width:
            x, y, row_height = 4, y + row_height + 8, 0
        if y + sprite.image.height + 4 > atlas.height:
            raise ValueError("Sprite atlas overflow")
        sprite.atlas_x, sprite.atlas_y = x, y
        atlas.paste(sprite.image, (x, y))
        x += sprite.image.width + 8
        row_height = max(row_height, sprite.image.height)
    return atlas


def encode_build(parts: dict[str, Sprite], name: str, atlas_size: int) -> bytes:
    stream = io.BytesIO()
    stream.write(struct.pack("<4sIII", b"BILD", 6, len(parts), len(parts)))
    write_string(stream, name)
    stream.write(struct.pack("<I", 1))
    write_string(stream, "atlas-0.tex")
    vertices = []
    for sprite in sorted(parts.values(), key=lambda s: name_hash(s.name)):
        w, h = sprite.image.size
        left, top, right, bottom = sprite.corners
        u1, u2 = sprite.atlas_x / atlas_size, (sprite.atlas_x + w) / atlas_size
        v1, v2 = 1 - sprite.atlas_y / atlas_size, 1 - (sprite.atlas_y + h) / atlas_size
        start = len(vertices)
        vertices.extend(
            [
                (left, top, 0, u1, v1, 0),
                (right, top, 0, u2, v1, 0),
                (left, bottom, 0, u1, v2, 0),
                (right, top, 0, u2, v1, 0),
                (right, bottom, 0, u2, v2, 0),
                (left, bottom, 0, u1, v2, 0),
            ]
        )
        stream.write(
            struct.pack(
                "<IIIIffffII",
                name_hash(sprite.name),
                1,
                0,
                1,
                w / 2 - sprite.pivot_x,
                h / 2 - sprite.pivot_y,
                w,
                h,
                start,
                6,
            )
        )
    stream.write(struct.pack("<I", len(vertices)))
    for vertex in vertices:
        stream.write(struct.pack("<ffffff", *vertex))
    write_hashes(stream, set(parts))
    return stream.getvalue()


def encode_animation(anims: list[Animation], parts: dict[str, Sprite], spec: dict) -> bytes:
    stream = io.BytesIO()
    total_frames = sum(len(a.frames) for a in anims)
    total_elements = sum(len(f) for a in anims for f in a.frames)
    stream.write(struct.pack("<4sIIIII", b"ANIM", 4, total_elements, total_frames, 0, len(anims)))
    names = {spec["name"]}
    for anim in anims:
        write_string(stream, anim.name)
        stream.write(
            struct.pack(
                "<BIfI", anim.facing, name_hash(spec["name"]), spec["fps"], len(anim.frames)
            )
        )
        for frame in anim.frames:
            stream.write(struct.pack("<ffffII", *bounds(frame, parts), 0, len(frame)))
            for index, element in enumerate(frame):
                names.update([element.sprite, element.layer])
                stream.write(
                    struct.pack(
                        "<IIIfffffff",
                        name_hash(element.sprite),
                        0,
                        name_hash(element.layer),
                        *element.matrix,
                        index / len(frame) * 10 - 5,
                    )
                )
    write_hashes(stream, names)
    return stream.getvalue()


def export_scml(anims: list[Animation], parts: dict[str, Sprite], spec: dict) -> None:
    """Editable Spriter source; the shared side is mirrored by DST at runtime."""
    root = ET.Element("spriter_data", scml_version="1.0", generator="Automatic Collector rig")
    folder = ET.SubElement(root, "folder", id="0", name="parts")
    ids = {}
    for index, sprite in enumerate(parts.values()):
        ids[sprite.name] = index
        ET.SubElement(
            folder,
            "file",
            id=str(index),
            name=f"parts/{sprite.name}.png",
            width=str(sprite.image.width),
            height=str(sprite.image.height),
            pivot_x=str(sprite.pivot_x / sprite.image.width),
            pivot_y=str(1 - sprite.pivot_y / sprite.image.height),
        )
    entity = ET.SubElement(root, "entity", id="0", name=spec["name"])
    for index, anim in enumerate(anims):
        length = len(anim.frames) * 1000 / spec["fps"]
        node = ET.SubElement(
            entity,
            "animation",
            id=str(index),
            name=f"{anim.name}_{anim.view}",
            length=str(round(length)),
            interval="33",
            looping="true" if anim.name in ("idle", "walk_loop") else "false",
        )
        mainline = ET.SubElement(node, "mainline")
        for frame_index, elements in enumerate(anim.frames):
            key = ET.SubElement(
                mainline,
                "key",
                id=str(frame_index),
                time=str(round(frame_index * 1000 / spec["fps"])),
            )
            for eid, _ in enumerate(elements):
                ET.SubElement(
                    key,
                    "object_ref",
                    id=str(eid),
                    timeline=str(eid),
                    key=str(frame_index),
                    z_index=str(eid),
                )
        for eid, first in enumerate(anim.frames[0]):
            timeline = ET.SubElement(
                node, "timeline", id=str(eid), name=first.layer, object_type="sprite"
            )
            for frame_index, elements in enumerate(anim.frames):
                element = elements[eid]
                key = ET.SubElement(
                    timeline,
                    "key",
                    id=str(frame_index),
                    time=str(round(frame_index * 1000 / spec["fps"])),
                    spin="0",
                )
                ET.SubElement(
                    key,
                    "object",
                    folder="0",
                    file=str(ids[element.sprite]),
                    x=str(element.x),
                    y=str(-element.y),
                    angle=str(-element.angle % 360),
                    scale_x=str(element.sx),
                    scale_y=str(element.sy),
                )
    ET.indent(root)
    ET.ElementTree(root).write(
        GENERATED / "automatic_collector.scml", encoding="utf-8", xml_declaration=True
    )


def render(elements: list[Element], parts: dict[str, Sprite]) -> Image.Image:
    """Render the same sprite matrices as the game for QA and icons."""
    canvas = Image.new("RGBA", (400, 320))
    for element in elements:
        sprite = parts[element.sprite]
        a, b, c, d, tx, ty = element.matrix
        tx += 200 - a * sprite.pivot_x - c * sprite.pivot_y
        ty += 280 - b * sprite.pivot_x - d * sprite.pivot_y
        det = a * d - b * c
        coeffs = (
            d / det,
            -c / det,
            (c * ty - d * tx) / det,
            -b / det,
            a / det,
            (b * tx - a * ty) / det,
        )
        layer = sprite.image.transform(
            canvas.size, Image.Transform.AFFINE, coeffs, Image.Resampling.BICUBIC
        )
        canvas.alpha_composite(layer)
    return canvas


def converter(tool_dir: Path, source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    executable = tool_dir / "tools/bin/TextureConverter.exe"
    if not executable.is_file():
        raise FileNotFoundError(f"Install Klei Mod Tools or specify --mod-tools: {executable}")
    subprocess.run(
        [
            str(executable),
            "--swizzle",
            "--format",
            "bc3",
            "--platform",
            "opengl",
            "--premultiply",
            "--mipmap",
            "-i",
            str(source),
            "-o",
            str(destination),
        ],
        check=True,
    )
    if destination.read_bytes()[:4] != b"KTEX":
        raise ValueError(f"Texture conversion failed: {destination}")


def icon(
    image: Image.Image,
    size: int,
    path: Path,
    tool_dir: Path,
    element_name: str,
    padding: int = 4,
) -> None:
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("Empty icon")
    thumb = image.crop(bbox)
    thumb.thumbnail((size - 2 * padding, size - 2 * padding), Image.Resampling.LANCZOS)
    output = Image.new("RGBA", (size, size))
    output.alpha_composite(thumb, ((size - thumb.width) // 2, (size - thumb.height) // 2))
    prefix = "inventory_" if path.parent.name == "inventoryimages" else ""
    png = GENERATED / f"{prefix}{path.name}.png"
    output.save(png)
    converter(tool_dir, png, path.with_suffix(".tex"))
    root = ET.Element("Atlas")
    ET.SubElement(root, "Texture", filename=path.with_suffix(".tex").name)
    elements = ET.SubElement(root, "Elements")
    edge = 0.5 / size
    ET.SubElement(
        elements,
        "Element",
        name=element_name,
        u1=str(edge),
        u2=str(1 - edge),
        v1=str(edge),
        v2=str(1 - edge),
    )
    ET.indent(root)
    ET.ElementTree(root).write(path.with_suffix(".xml"), encoding="utf-8", xml_declaration=True)


def previews(anims: list[Animation], parts: dict[str, Sprite]) -> None:
    font = ImageFont.load_default(size=18)
    rows = []
    for anim in anims:
        if anim.view != "right":
            continue
        chosen = [0, len(anim.frames) // 3, len(anim.frames) // 2, 2 * len(anim.frames) // 3]
        row = Image.new("RGB", (1600, 360), "#e8ddc4")
        ImageDraw.Draw(row).text((16, 10), anim.name, font=font, fill="#352c26")
        for column, index in enumerate(chosen):
            frame = render(anim.frames[index], parts)
            row.paste(frame, (column * 400, 35), frame)
        rows.append(row)
        if anim.name in ("walk_loop", "pickup", "hammer", "store"):
            frames = []
            for elements in anim.frames:
                bg = Image.new("RGBA", (400, 320), "#e8ddc4")
                bg.alpha_composite(render(elements, parts))
                frames.append(bg.convert("RGB"))
            frames[0].save(
                GENERATED / f"{anim.name}.gif",
                save_all=True,
                append_images=frames[1:],
                duration=33,
                loop=0,
                disposal=2,
            )
    contact = Image.new("RGB", (1600, 360 * len(rows)), "#e8ddc4")
    for i, row in enumerate(rows):
        contact.paste(row, (0, i * 360))
    contact.save(GENERATED / "animation_contact_sheet.png")
    views = Image.new("RGB", (1600, 360), "#e8ddc4")
    for i, view in enumerate(["down", "right", "up", "left"]):
        frame = render(pose("idle", view, 0), parts)
        views.paste(frame, (i * 400, 35), frame)
        ImageDraw.Draw(views).text((i * 400 + 16, 10), view, font=font, fill="#352c26")
    views.save(GENERATED / "four_views.png")


def build(tool_dir: Path) -> None:
    WORK.mkdir(parents=True, exist_ok=True)
    GENERATED.mkdir(parents=True, exist_ok=True)
    spec = json.loads((SOURCE / "rig.json").read_text(encoding="utf-8"))
    parts = extract_parts(spec)
    atlas = pack_atlas(parts)
    atlas_path = GENERATED / "atlas.png"
    atlas.save(atlas_path)
    converter(tool_dir, atlas_path, WORK / "atlas-0.tex")
    anims = animations(spec)
    (ROOT / "anim").mkdir(exist_ok=True)
    with zipfile.ZipFile(ROOT / "anim/automatic_collector.zip", "w", zipfile.ZIP_DEFLATED) as z:
        data = {
            "build.bin": encode_build(parts, spec["name"], atlas.width),
            "anim.bin": encode_animation(anims, parts, spec),
            "atlas-0.tex": (WORK / "atlas-0.tex").read_bytes(),
        }
        for name, content in data.items():
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(entry, content)
    export_scml(anims, parts, spec)
    previews(anims, parts)
    image = render(pose("idle", "down", 0), parts)
    icon(
        image,
        64,
        ROOT / "images/inventoryimages/automatic_collector",
        tool_dir,
        "automatic_collector.tex",
        padding=8,
    )
    icon(
        image,
        64,
        ROOT / "images/map_icons/automatic_collector",
        tool_dir,
        "automatic_collector.tex",
    )
    icon(image, 256, ROOT / "modicon", tool_dir, "modicon.tex")
    print(
        f"Built {len(anims)} animations, {sum(len(a.frames) for a in anims)} frames, {len(parts)} sprites"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mod-tools", type=Path, default=DEFAULT_TOOLS)
    build(parser.parse_args().mod_tools)
