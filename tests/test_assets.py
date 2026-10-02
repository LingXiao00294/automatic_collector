"""Read shipping binary assets independently and check runtime contract invariants."""

import json
import struct
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

import pytest
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0

    def values(self, fmt: str):
        result = struct.unpack_from("<" + fmt, self.data, self.offset)
        self.offset += struct.calcsize("<" + fmt)
        return result

    def string(self) -> str:
        (length,) = self.values("I")
        value = self.data[self.offset : self.offset + length].decode("ascii")
        self.offset += length
        return value

    def hashes(self) -> dict[int, str]:
        (count,) = self.values("I")
        names = {}
        for _ in range(count):
            (key,) = self.values("I")
            names[key] = self.string()
        assert self.offset == len(self.data), "Trailing or truncated data"
        return names


def test_animation_runtime_contract():
    with ZipFile(ROOT / "anim/automatic_collector.zip") as archive:
        assert set(archive.namelist()) == {"anim.bin", "build.bin", "atlas-0.tex"}
        reader = Reader(archive.read("anim.bin"))
        magic, version, total_elements, total_frames, events, count = reader.values("4sIIIII")
        assert (magic, version, events, count) == (b"ANIM", 4, 0, 21)
        actual_frames, actual_elements = 0, 0
        facings = {}
        symbols = set()
        for _ in range(count):
            name = reader.string()
            facing, _, fps, frames = reader.values("BIfI")
            facings.setdefault(name, set()).add(facing)
            assert fps == 30
            for frame_index in range(frames):
                _, _, w, h, event_count, elements = reader.values("ffffII")
                assert w > 0 and h > 0 and event_count == 0
                assert elements == 1, "Only the chassis belongs in the simplified model"
                for _ in range(elements):
                    symbol, _, _, a, b, c, d, x, y, _ = reader.values("IIIfffffff")
                    assert abs(a * d - b * c) > 0.1, "Degenerate sprite matrix"
                    symbols.add(symbol)
                    if name == "pickup" and frame_index == 15:
                        assert y == pytest.approx(18) and abs(d) == pytest.approx(0.88)
                        assert x == pytest.approx(0), "Pickup sinks over the reached target"
                    if name == "hammer" and facing == 5 and frame_index == 21:
                        assert x == pytest.approx(32), "Keep the approved bumper ram contact"
                    if name == "store" and frame_index < 6:
                        assert y < 8, "Delivery must not reach contact before frame 6"
                    if name == "store" and frame_index == 6:
                        assert y == pytest.approx(8), "Native STORE must match the nod contact"
                actual_frames += 1
                actual_elements += elements
        assert actual_frames == total_frames == 585
        assert actual_elements == total_elements
        assert set(facings) == {
            "idle",
            "walk_pre",
            "walk_loop",
            "walk_pst",
            "pickup",
            "hammer",
            "store",
        }
        assert all(facing == {2, 5, 8} for facing in facings.values())
        names = reader.hashes()
        assert {names[symbol] for symbol in symbols} == {"body_front", "body_side", "body_back"}


def test_build_atlas_vertices():
    with ZipFile(ROOT / "anim/automatic_collector.zip") as archive:
        reader = Reader(archive.read("build.bin"))
        assert reader.values("4sIII") == (b"BILD", 6, 3, 3)
        assert reader.string() == "automatic_collector"
        assert reader.values("I") == (1,)
        assert reader.string() == "atlas-0.tex"
        ranges = []
        for _ in range(3):
            _, count, frame, duration, _, _, w, h, first, vertices = reader.values("IIIIffffII")
            assert count == 1 and frame == 0 and duration == 1 and w > 0 and h > 0
            ranges.append((first, vertices))
        assert reader.values("I") == (18,)
        for _ in range(18):
            _, _, _, u, v, sampler = reader.values("ffffff")
            assert 0 <= u <= 1 and 0 <= v <= 1 and sampler == 0
        assert sorted(ranges) == [(i * 6, 6) for i in range(3)]
        assert set(reader.hashes().values()) == {"body_front", "body_side", "body_back"}
        assert archive.read("atlas-0.tex")[:4] == b"KTEX"


@pytest.mark.parametrize(
    "path",
    [
        "modicon",
        "images/inventoryimages/automatic_collector",
        "images/map_icons/automatic_collector",
    ],
)
def test_icons(path):
    atlas = ET.parse(ROOT / f"{path}.xml")
    texture = atlas.find("Texture")
    assert texture is not None
    assert (ROOT / path).with_name(texture.attrib["filename"]).read_bytes()[:4] == b"KTEX"
    elements = atlas.findall("Elements/Element")
    assert len(elements) == 1 and elements[0].attrib["name"].endswith(".tex")
    if path == "images/inventoryimages/automatic_collector":
        data = (ROOT / f"{path}.tex").read_bytes()
        assert struct.unpack_from("<HH", data, 8) == (64, 64)
        preview = Image.open(ROOT / "assets/generated/inventory_automatic_collector.png")
        assert preview.size == (64, 64)
        bbox = preview.getchannel("A").getbbox()
        assert bbox is not None
        assert bbox[2] - bbox[0] <= 48 and bbox[3] - bbox[1] <= 48


def test_editable_source():
    spec = json.loads((ROOT / "assets/source/rig.json").read_text())
    assert spec["animations"]["store"]["impact_frame"] / spec["fps"] == 0.2
    scml = ET.parse(ROOT / "assets/generated/automatic_collector.scml")
    animations = scml.findall("entity/animation")
    assert len(animations) == 21
    assert len(scml.findall("folder/file")) == 3
    for animation in animations:
        name = animation.attrib["name"].rsplit("_", 1)[0]
        assert len(animation.findall("mainline/key")) == spec["animations"][name]["frames"]
    expected_files = {definition["source"] for definition in spec["parts"].values()}
    assert expected_files == {"body_front.png", "body_side.png", "body_back.png"}
    for directory in [ROOT / "assets/source", ROOT / "assets/generated/parts"]:
        assert {path.name for path in directory.glob("*.png")} == expected_files
        for name in expected_files:
            sprite = Image.open(directory / name)
            assert sprite.height == 140 and sprite.getchannel("A").getextrema() == (0, 255)
