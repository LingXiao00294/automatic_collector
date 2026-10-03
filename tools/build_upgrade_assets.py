"""Build the approved MK II chassis and kit without changing the base collector assets."""

from __future__ import annotations

import argparse
import itertools
import json
import math
import zipfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from tools import build_assets as assets

SOURCE = assets.SOURCE / "upgrade"
GENERATED = assets.GENERATED / "upgrade"
CANVAS = (520, 320)
BACKGROUND = "#e8ddc4"


def gif_delays(frame_count: int, fps: float, speed: float) -> list[int]:
    """GIF uses centiseconds; distribute rounding instead of shortening every frame."""
    ticks = [round(index * 100 / (fps * speed)) for index in range(frame_count + 1)]
    return [(end - start) * 10 for start, end in itertools.pairwise(ticks)]


def save_gif(path: Path, frames: list[Image.Image], durations: list[int]) -> None:
    frames[0].save(
        path,
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        disposal=2,
    )


def check_preview_bounds(elements: list[assets.Element], parts: dict[str, assets.Sprite]) -> None:
    cx, cy, width, height = assets.bounds(elements, parts)
    x, y = CANVAS[0] / 2 + cx, CANVAS[1] - 40 + cy
    if x - width / 2 < 0 or x + width / 2 > CANVAS[0]:
        raise ValueError("Animation exceeds preview width")
    if y - height / 2 < 0 or y + height / 2 > CANVAS[1]:
        raise ValueError("Animation exceeds preview height")


def preview_frame(elements: list[assets.Element], parts: dict[str, assets.Sprite]) -> Image.Image:
    check_preview_bounds(elements, parts)
    frame = Image.new("RGBA", CANVAS, BACKGROUND)
    frame.alpha_composite(assets.render(elements, parts, CANVAS))
    return frame.convert("RGB")


def speed_for(name: str, spec: dict) -> float:
    if name.startswith("walk"):
        return spec["preview_move_speed"]
    return 1 if name == "idle" else spec["preview_action_speed"]


def chassis_previews(
    anims: list[assets.Animation], parts: dict[str, assets.Sprite], spec: dict, output: Path
) -> None:
    font = ImageFont.load_default(size=18)
    for animation in anims:
        for frame in animation.frames:
            check_preview_bounds(frame, parts)
    views = Image.new("RGB", (CANVAS[0] * 2, CANVAS[1] * 2), BACKGROUND)
    for index, view in enumerate(("down", "right", "up", "left")):
        frame = preview_frame(assets.pose("idle", view, 0), parts)
        ImageDraw.Draw(frame).text((16, 14), view, font=font, fill="#352c26")
        views.paste(frame, ((index % 2) * CANVAS[0], (index // 2) * CANVAS[1]))
    views.save(output / "four_views.png")

    right = {anim.name: anim for anim in anims if anim.view == "right"}
    contact = Image.new("RGB", (CANVAS[0] * 4, CANVAS[1] * 3), BACKGROUND)
    for row, name in enumerate(("pickup", "hammer", "store")):
        anim = right[name]
        impact = spec["animations"][name]["impact_frame"]
        speed = speed_for(name, spec)
        for column, index in enumerate((0, impact - 1, impact, len(anim.frames) - 1)):
            frame = preview_frame(anim.frames[index], parts)
            label = f"{name}: frame {index}, t={index / spec['fps'] / speed:.3f}s"
            if index == impact:
                label += " / CONTACT"
            ImageDraw.Draw(frame).text((16, 14), label, font=font, fill="#352c26")
            contact.paste(frame, (column * CANVAS[0], row * CANVAS[1]))
    contact.save(output / "animation_contact_sheet.png")

    for anim in anims:
        if anim.view == "right":
            frames = [preview_frame(frame, parts) for frame in anim.frames]
            save_gif(
                output / f"{anim.name}.gif",
                frames,
                gif_delays(len(frames), spec["fps"], speed_for(anim.name, spec)),
            )

    showcase = []
    for tick in range(40):
        time = tick / 20
        sheet = Image.new("RGB", (CANVAS[0] * 2, CANVAS[1] * 2), BACKGROUND)
        for cell, name in enumerate(("walk_loop", "pickup", "hammer", "store")):
            anim = right[name]
            speed = speed_for(name, spec)
            duration = len(anim.frames) / spec["fps"] / speed
            phase = time % (duration if name == "walk_loop" else duration + 0.4)
            index = min(len(anim.frames) - 1, math.floor(phase * spec["fps"] * speed))
            frame = preview_frame(anim.frames[index], parts)
            label = f"{name} / {speed:g}x"
            ImageDraw.Draw(frame).text((16, 14), label, font=font, fill="#352c26")
            sheet.paste(frame, ((cell % 2) * CANVAS[0], (cell // 2) * CANVAS[1]))
        showcase.append(sheet)
    save_gif(output / "showcase.gif", showcase, [50] * len(showcase))


def write_archive(
    name: str,
    parts: dict[str, assets.Sprite],
    atlas: Image.Image,
    texture: Path,
    anims: list[assets.Animation],
    spec: dict,
) -> None:
    payload = {
        "build.bin": assets.encode_build(parts, name, atlas.width),
        "atlas-0.tex": texture.read_bytes(),
        "anim.bin": assets.encode_animation(anims, parts, spec),
    }
    destination = assets.ROOT / "anim" / f"{name}.zip"
    destination.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(destination, "w") as archive:
        for member, content in payload.items():
            entry = zipfile.ZipInfo(member, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, content)


def build(tool_dir: Path) -> None:
    for kind, filename in (("collector", "rig.json"), ("kit", "kit_rig.json")):
        spec = json.loads((SOURCE / filename).read_text(encoding="utf-8"))
        output = GENERATED / kind
        output.mkdir(parents=True, exist_ok=True)
        parts = assets.extract_parts(spec, SOURCE, output)
        atlas = assets.pack_atlas(parts)
        atlas_path = output / "atlas.png"
        atlas.save(atlas_path)
        texture = assets.WORK / "upgrade" / kind / "atlas-0.tex"
        assets.converter(tool_dir, atlas_path, texture)
        if kind == "collector":
            base_spec = json.loads((assets.SOURCE / "rig.json").read_text(encoding="utf-8"))
            if spec["animations"] != base_spec["animations"] or spec["fps"] != base_spec["fps"]:
                raise ValueError("MK II must preserve the collector action frames and timing")
            anims = assets.animations(spec)
            chassis_previews(anims, parts, spec, output)
            icon_image = assets.render(assets.pose("idle", "down", 0), parts, CANVAS)
        else:
            anims = [
                assets.Animation("idle", "all", 255, [[assets.Element("kit_world", "body", 0, 0)]])
            ]
            icon_image = assets.render(anims[0].frames[0], parts, CANVAS)
            parts["kit_world"].image.save(output / "world.png")
            preview_frame(anims[0].frames[0], parts).save(output / "world_preview.png")
        write_archive(spec["name"], parts, atlas, texture, anims, spec)
        assets.export_scml(anims, parts, spec, output)
        assets.icon(
            icon_image,
            64,
            assets.ROOT / "images/inventoryimages" / spec["name"],
            tool_dir,
            f"{spec['name']}.tex",
            padding=8,
            generated=output,
        )
        if kind == "collector":
            assets.icon(
                icon_image,
                64,
                assets.ROOT / "images/map_icons" / spec["name"],
                tool_dir,
                f"{spec['name']}.tex",
                generated=output,
            )
        print(f"Built {spec['name']}: {len(parts)} sprites; previews at {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mod-tools", type=Path, default=assets.DEFAULT_TOOLS)
    build(parser.parse_args().mod_tools)
