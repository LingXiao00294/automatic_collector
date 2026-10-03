"""Read shipping binary assets independently and check runtime contract invariants."""

import json
import struct
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

import pytest
from PIL import Image, ImageSequence

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


@pytest.mark.parametrize("bank_name", ["automatic_collector", "automatic_collector_mk2"])
def test_animation_runtime_contract(bank_name):
    with ZipFile(ROOT / f"anim/{bank_name}.zip") as archive:
        assert set(archive.namelist()) == {"anim.bin", "build.bin", "atlas-0.tex"}
        build = Reader(archive.read("build.bin"))
        _, _, symbol_count, _ = build.values("4sIII")
        build.string()
        for _ in range(build.values("I")[0]):
            build.string()
        rectangles = {}
        for _ in range(symbol_count):
            symbol, _, _, _, cx, cy, width, height, _, _ = build.values("IIIIffffII")
            rectangles[symbol] = (cx - width / 2, cy - height / 2, cx + width / 2, cy + height / 2)
        reader = Reader(archive.read("anim.bin"))
        magic, version, total_elements, total_frames, events, count = reader.values("4sIIIII")
        assert (magic, version, events, count) == (b"ANIM", 4, 0, 21)
        actual_frames, actual_elements = 0, 0
        facings = {}
        symbols = set()
        banks = set()
        for _ in range(count):
            name = reader.string()
            facing, bank, fps, frames = reader.values("BIfI")
            banks.add(bank)
            facings.setdefault(name, set()).add(facing)
            assert fps == 30
            for frame_index in range(frames):
                frame_cx, frame_cy, w, h, event_count, elements = reader.values("ffffII")
                assert w > 0 and h > 0 and event_count == 0
                assert elements == 1, "Only the chassis belongs in the simplified model"
                for _ in range(elements):
                    symbol, _, _, a, b, c, d, x, y, _ = reader.values("IIIfffffff")
                    assert abs(a * d - b * c) > 0.1, "Degenerate sprite matrix"
                    symbols.add(symbol)
                    left, top, right, bottom = rectangles[symbol]
                    for px, py in ((left, top), (right, top), (left, bottom), (right, bottom)):
                        tx, ty = a * px + c * py + x, b * px + d * py + y
                        assert frame_cx - w / 2 - 0.001 <= tx <= frame_cx + w / 2 + 0.001
                        assert frame_cy - h / 2 - 0.001 <= ty <= frame_cy + h / 2 + 0.001
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
        assert {names[bank] for bank in banks} == {bank_name}
        assert {names[symbol] for symbol in symbols} == {"body_front", "body_side", "body_back"}


@pytest.mark.parametrize(
    ("build_name", "symbols"),
    [
        ("automatic_collector", {"body_front", "body_side", "body_back"}),
        ("automatic_collector_mk2", {"body_front", "body_side", "body_back"}),
        ("ac_upgrade_kit", {"kit_world"}),
    ],
)
def test_build_atlas_vertices(build_name, symbols):
    symbol_count = len(symbols)
    with ZipFile(ROOT / f"anim/{build_name}.zip") as archive:
        reader = Reader(archive.read("build.bin"))
        assert reader.values("4sIII") == (b"BILD", 6, symbol_count, symbol_count)
        assert reader.string() == build_name
        assert reader.values("I") == (1,)
        assert reader.string() == "atlas-0.tex"
        ranges = []
        for _ in range(symbol_count):
            _, count, frame, duration, _, _, w, h, first, vertices = reader.values("IIIIffffII")
            assert count == 1 and frame == 0 and duration == 1 and w > 0 and h > 0
            ranges.append((first, vertices))
        assert reader.values("I") == (symbol_count * 6,)
        for _ in range(symbol_count * 6):
            _, _, _, u, v, sampler = reader.values("ffffff")
            assert 0 <= u <= 1 and 0 <= v <= 1 and sampler == 0
        assert sorted(ranges) == [(i * 6, 6) for i in range(symbol_count)]
        assert set(reader.hashes().values()) == symbols
        assert archive.read("atlas-0.tex")[:4] == b"KTEX"


@pytest.mark.parametrize(
    "path",
    [
        "modicon",
        "images/inventoryimages/automatic_collector",
        "images/map_icons/automatic_collector",
        "images/inventoryimages/automatic_collector_mk2",
        "images/map_icons/automatic_collector_mk2",
        "images/inventoryimages/ac_upgrade_kit",
    ],
)
def test_icons(path):
    atlas = ET.parse(ROOT / f"{path}.xml")
    texture = atlas.find("Texture")
    assert texture is not None
    assert (ROOT / path).with_name(texture.attrib["filename"]).read_bytes()[:4] == b"KTEX"
    elements = atlas.findall("Elements/Element")
    assert len(elements) == 1 and elements[0].attrib["name"].endswith(".tex")
    if path.startswith("images/inventoryimages/"):
        data = (ROOT / f"{path}.tex").read_bytes()
        assert struct.unpack_from("<HH", data, 8) == (64, 64)
        preview_directory = {
            "automatic_collector": "assets/generated",
            "automatic_collector_mk2": "assets/generated/upgrade/collector",
            "ac_upgrade_kit": "assets/generated/upgrade/kit",
        }[Path(path).name]
        preview = Image.open(ROOT / preview_directory / f"inventory_{Path(path).name}.png")
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


def test_upgrade_has_its_own_bank_with_unchanged_action_frames():
    spec = json.loads((ROOT / "assets/source/upgrade/rig.json").read_text())
    base = json.loads((ROOT / "assets/source/rig.json").read_text())
    assert spec["bank"] == spec["name"] == "automatic_collector_mk2"
    assert spec["animations"] == base["animations"] and spec["fps"] == base["fps"]
    assert (spec["preview_move_speed"], spec["preview_action_speed"]) == (2, 1)
    with ZipFile(ROOT / "anim/automatic_collector_mk2.zip") as archive:
        assert set(archive.namelist()) == {"build.bin", "anim.bin", "atlas-0.tex"}
    source = ET.parse(ROOT / "assets/generated/upgrade/collector/automatic_collector_mk2.scml")
    assert len(source.findall("folder/file")) == 3
    animations = source.findall("entity/animation")
    assert len(animations) == 21
    assert {anim.attrib["name"].rsplit("_", 1)[1] for anim in animations} == {"up", "down", "right"}
    for anim in animations:
        name = anim.attrib["name"].rsplit("_", 1)[0]
        assert len(anim.findall("mainline/key")) == base["animations"][name]["frames"]


def test_kit_idle_uses_its_own_all_facing_bank():
    with ZipFile(ROOT / "anim/ac_upgrade_kit.zip") as archive:
        assert set(archive.namelist()) == {"build.bin", "anim.bin", "atlas-0.tex"}
        reader = Reader(archive.read("anim.bin"))
        assert reader.values("4sIIIII") == (b"ANIM", 4, 1, 1, 0, 1)
        assert reader.string() == "idle"
        facing, bank, fps, frames = reader.values("BIfI")
        assert (facing, fps, frames) == (255, 30, 1)
        _, _, width, height, events, elements = reader.values("ffffII")
        assert width > 0 and height == 56 and events == 0 and elements == 1
        symbol, _, _, a, b, c, d, x, y, _ = reader.values("IIIfffffff")
        assert (a, b, c, d, x, y) == (1, 0, 0, 1, 0, 0)
        names = reader.hashes()
        assert names[bank] == "ac_upgrade_kit" and names[symbol] == "kit_world"


@pytest.mark.parametrize(
    ("animation", "duration"),
    [("idle", 2000), ("walk_loop", 400), ("pickup", 1000), ("hammer", 1300), ("store", 1000)],
)
def test_upgrade_gif_timing_matches_latest_plan(animation, duration):
    with Image.open(ROOT / f"assets/generated/upgrade/collector/{animation}.gif") as preview:
        elapsed = 0
        for frame in ImageSequence.Iterator(preview):
            elapsed += frame.info["duration"]
        assert elapsed == duration


@pytest.mark.parametrize("name", ["body_front", "body_side", "body_back", "kit_world"])
def test_upgrade_sources_have_true_transparency_and_scaled_parts(name):
    with Image.open(ROOT / f"assets/source/upgrade/{name}.png") as source:
        assert source.mode == "RGBA"
        minimum, maximum = source.getchannel("A").getextrema()
        assert minimum == 0 and isinstance(maximum, (int, float)) and maximum >= 250
    kind = "kit" if name == "kit_world" else "collector"
    with Image.open(ROOT / f"assets/generated/upgrade/{kind}/parts/{name}.png") as scaled:
        assert scaled.height == (56 if kind == "kit" else 140)
        if name in {"body_front", "body_back"}:
            assert scaled.width == 220, "Front and rear must keep the same chassis width"
        assert scaled.getchannel("A").getextrema()[0] == 0
