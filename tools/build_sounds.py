"""Synthesize original collector effects and compile a DST FMOD Designer bank."""

import argparse
import math
import random
import struct
import subprocess
import uuid
import wave
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TOOLS = Path("D:/Programs/Steam/steamapps/common/Don't Starve Mod Tools/mod_tools")
RATE = 22050
BANK = "ac_collector"
DURATIONS = {
    "walk_loop": 0.8,
    "pickup": 0.28,
    "pick": 0.35,
    "hammer": 0.45,
    "store": 0.32,
    "start": 0.38,
    "stop": 0.28,
    "upgrade": 0.6,
}


def synthesize(profile: str, cue: str) -> list[float]:
    """Deterministic modal impacts, filtered friction and mechanical hum; no samples."""
    metal = profile == "metal"
    duration = 0.4 if metal and cue == "walk_loop" else DURATIONS[cue]
    samples = [0.0] * round(duration * RATE)
    rng = random.Random(profile + ":" + cue)
    modes = (610, 1030, 1760) if metal else (175, 370, 690)
    friction = 0.0
    for index in range(len(samples)):
        time = index / RATE
        friction = 0.82 * friction + 0.18 * rng.uniform(-1, 1)
        if cue == "walk_loop":
            # Four wheel/gear accents, spaced to match each chassis' walk cycle.
            phase = time % (duration / 4)
            envelope = math.exp(-phase * (85 if metal else 42))
            hum = math.sin(2 * math.pi * (100 if metal else 55) * time)
            samples[index] = (
                0.1 * hum
                + 0.15 * friction
                + envelope
                * sum(math.sin(2 * math.pi * f * phase) / (i + 1) for i, f in enumerate(modes))
            )
        else:
            offsets = {
                "pickup": (0, 0.075),
                "pick": (0, 0.11),
                "hammer": (0,),
                "store": (0, 0.12),
                "start": (0, 0.09, 0.18),
                "stop": (0, 0.075),
                "upgrade": (0, 0.12, 0.24, 0.36),
            }[cue]
            value = 0.0
            for onset in offsets:
                phase = time - onset
                if phase < 0:
                    continue
                decay = 17 if cue == "hammer" else 28 if metal else 36
                attack = min(1, phase / 0.003)
                impact = sum(
                    math.sin(2 * math.pi * f * phase) / (i + 1) for i, f in enumerate(modes)
                )
                value += attack * math.exp(-phase * decay) * (impact + 0.65 * friction)
            if metal and cue in {"start", "upgrade"}:
                frequency = 190 + 210 * time / duration
                value += (
                    0.16
                    * math.sin(2 * math.pi * frequency * time)
                    * math.sin(math.pi * time / duration)
                )
            if cue == "pick":
                value += 0.45 * friction * math.sin(math.pi * time / duration) ** 2
            samples[index] = value
        # Both ends are zero, including loop seams; keep headroom for multiple carts.
        edge = min(1, index / (RATE * 0.006), (len(samples) - 1 - index) / (RATE * 0.02))
        samples[index] *= max(0, edge)
    peak = max(abs(value) for value in samples)
    gain = (0.22 if cue == "walk_loop" else 0.55) / peak
    return [value * gain for value in samples]


def write_wav(path: Path, samples: list[float]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        output.writeframes(b"".join(struct.pack("<h", round(value * 32767)) for value in samples))


def child(parent: ET.Element, tag: str, value: str | float) -> ET.Element:
    node = ET.SubElement(parent, tag)
    node.text = str(value)
    return node


def make_project(source: Path) -> Path:
    project = ET.Element("project")
    child(project, "name", BANK)
    child(project, "version", 4)
    child(project, "currentlanguage", "english")
    child(project, "primarylanguage", "english")
    child(project, "language", "english")
    definitions = ET.SubElement(project, "sounddeffolder")
    child(definitions, "name", "master")
    bank = ET.SubElement(project, "soundbank")
    child(bank, "name", BANK)
    child(bank, "_PC_banktype", "DecompressedSample")
    for profile in ("wood", "metal"):
        group = ET.SubElement(project, "eventgroup")
        child(group, "name", profile)
        for cue, duration in DURATIONS.items():
            if profile == "wood" and cue == "upgrade":
                continue
            name = f"{profile}_{cue}"
            waveform = ET.SubElement(bank, "waveform")
            child(waveform, "filename", name + ".wav")
            child(waveform, "deffreq", RATE)
            child(waveform, "defvol", 1)
            definition = ET.SubElement(definitions, "sounddef")
            child(definition, "name", "/" + name)
            child(definition, "type", "sequential")
            child(definition, "spawn_max", 1)
            child(definition, "mode", 0)
            child(definition, "volume_db", 0)
            entry = ET.SubElement(definition, "waveform")
            child(entry, "filename", name + ".wav")
            child(entry, "soundbankname", BANK)
            child(entry, "weight", 100)
            child(entry, "percentagelocked", 0)
            event = ET.SubElement(group, "event")
            child(event, "name", cue)
            child(event, "oneshot", "No" if cue == "walk_loop" else "Yes")
            child(event, "mode", "x_3d")
            child(event, "mindistance", 2)
            child(event, "maxdistance", 18)
            child(event, "rolloff", "Linear")
            child(event, "volume_db", -8 if cue == "walk_loop" else -3)
            child(event, "maxplaybacks", 8)
            child(event, "maxplaybacks_behavior", "Steal_oldest")
            layer = ET.SubElement(event, "layer")
            child(layer, "name", "layer00")
            child(layer, "_PC_enable", 1)
            sound = ET.SubElement(layer, "sound")
            child(sound, "name", "/" + name)
            child(sound, "x", 0)
            child(sound, "width", duration)
            child(sound, "startmode", 0)
            child(sound, "loopmode", 0 if cue == "walk_loop" else 1)
            child(sound, "loopcount2", -1 if cue == "walk_loop" else 0)
            child(sound, "volume", 1)
    for index, node in enumerate(list(project.iter())):
        if node.tag in {
            "project",
            "soundbank",
            "sounddef",
            "sounddeffolder",
            "eventgroup",
            "event",
        }:
            child(node, "guid", "{" + str(uuid.uuid5(uuid.NAMESPACE_URL, f"{BANK}/{index}")) + "}")
    ET.indent(project)
    path = source / f"{BANK}.fdp"
    ET.ElementTree(project).write(path, encoding="utf-8", xml_declaration=True)
    return path


def build(mod_tools: Path = DEFAULT_TOOLS, root: Path = ROOT) -> None:
    source = root / "assets/source/audio"
    previews = root / "assets/generated/audio"
    source.mkdir(parents=True, exist_ok=True)
    for profile in ("wood", "metal"):
        sequence: list[float] = []
        for cue in DURATIONS:
            if profile == "wood" and cue == "upgrade":
                continue
            samples = synthesize(profile, cue)
            write_wav(source / f"{profile}_{cue}.wav", samples)
            sequence.extend(samples * (3 if cue == "walk_loop" else 1))
            sequence.extend([0.0] * round(RATE * 0.35))
        write_wav(previews / f"{profile}_showcase.wav", sequence)
    project = make_project(source)
    compiler = mod_tools / "FMOD_Designer/fmod_designercl.exe"
    if not compiler.is_file():
        raise FileNotFoundError(f"Install Klei Mod Tools or specify --mod-tools: {compiler}")
    output = root / "sound"
    output.mkdir(exist_ok=True)
    # Compiler cache remains in the ignored workspace, outside distributable sound/.
    cache = root / ".cache/sound_build"
    cache.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [str(compiler), "-pc", "-c", "pcm", "-a", str(source), "-b", str(cache), str(project)],
        cwd=cache,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stdout + result.stderr)
    for extension in ("fev", "fsb"):
        compiled = cache / f"{BANK}.{extension}"
        if not compiled.is_file() or "ERROR:" in result.stdout:
            raise RuntimeError(result.stdout + result.stderr)
        (output / compiled.name).write_bytes(compiled.read_bytes())
    print(result.stdout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mod-tools", type=Path, default=DEFAULT_TOOLS)
    build(parser.parse_args().mod_tools)
