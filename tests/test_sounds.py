"""Verify original PCM, shipping banks and optional native FMOD lifecycle without a game."""

import ctypes
import math
import os
import struct
import time
import wave
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

from tools.build_sounds import BANK, DURATIONS, RATE

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/source/audio"
GAME_BIN = Path("D:/Programs/Steam/steamapps/common/Don't Starve Together/bin64")


def test_original_samples_and_loop_seams():
    for profile in ("wood", "metal"):
        for cue, duration in DURATIONS.items():
            if profile == "wood" and cue == "upgrade":
                continue
            with wave.open(str(SOURCE / f"{profile}_{cue}.wav"), "rb") as audio:
                assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (
                    1,
                    2,
                    RATE,
                )
                expected = 0.4 if profile == "metal" and cue == "walk_loop" else duration
                assert audio.getnframes() == round(expected * RATE)
                data = audio.readframes(audio.getnframes())
            samples = struct.unpack(f"<{len(data) // 2}h", data)
            assert samples[0] == samples[-1] == 0
            assert 0 < max(abs(value) for value in samples) < 19000
            rms = math.sqrt(sum(value**2 for value in samples) / len(samples))
            assert rms > 300, "An accidentally silent effect"
            assert abs(sum(samples) / len(samples)) < 100, "DC offset"
            if profile == "metal" and cue != "upgrade":
                assert data != (SOURCE / f"wood_{cue}.wav").read_bytes()[44:]


def test_compiled_bank_contains_exact_pcm():
    data = (ROOT / f"sound/{BANK}.fsb").read_bytes()
    assert data[:4] == b"FSB5"
    count, headers, names, payload, codec = struct.unpack_from("<5I", data, 8)
    assert count == 15 and codec == 2, "PCM16 bank with all effects"
    assert len(data) == 60 + headers + names + payload
    names_start = 60 + headers
    payload_start = names_start + names
    found = set()
    for index in range(count):
        offset = struct.unpack_from("<I", data, names_start + index * 4)[0]
        start = names_start + offset
        name = data[start : data.index(0, start)].decode("ascii")
        packed = struct.unpack_from("<Q", data, 60 + index * 8)[0]
        assert packed & 1 == 0, "No extra chunks for simple mono PCM samples"
        audio_offset = ((packed >> 6) & ((1 << 28) - 1)) * 16
        frames = packed >> 34
        with wave.open(str(SOURCE / f"{name}.wav"), "rb") as audio:
            assert frames == audio.getnframes()
            raw = audio.readframes(frames)
        assert data[payload_start + audio_offset : payload_start + audio_offset + frames * 2] == raw
        found.add(name)
    assert found == {path.stem for path in SOURCE.glob("*.wav")}
    event_bank = (ROOT / f"sound/{BANK}.fev").read_bytes()
    assert event_bank[:4] == b"RIFF" and event_bank[8:12] == b"FEV "


def test_event_paths_and_source_references():
    project = ET.parse(SOURCE / f"{BANK}.fdp").getroot()
    definitions = {
        node.findtext("name"): node for node in project.findall("sounddeffolder/sounddef")
    }
    events = {}
    for group in project.findall("eventgroup"):
        for event in group.findall("event"):
            profile, cue = group.findtext("name"), event.findtext("name")
            assert profile is not None and cue is not None
            name = profile + "/" + cue
            events[name] = event
            sound = event.find("layer/sound")
            assert sound is not None
            definition = definitions[sound.findtext("name")]
            filename = definition.findtext("waveform/filename")
            assert filename is not None and (SOURCE / filename).is_file()
            assert definition.findtext("waveform/soundbankname") == BANK
            assert event.findtext("mode") == "x_3d"
            assert event.findtext("oneshot") == ("No" if name.endswith("walk_loop") else "Yes")
    assert len(events) == len(definitions) == 15
    for profile in ("wood", "metal"):
        assert all(f"{profile}/{cue}" in events for cue in DURATIONS if cue != "upgrade")
    assert "metal/upgrade" in events


@pytest.mark.skipif(
    os.name != "nt" or not (GAME_BIN / "fmod_event64.dll").is_file(),
    reason="Optional native FMOD DLLs are not installed; no game is started",
)
def test_native_fmod_events_end_and_loops_stop():
    with os.add_dll_directory(str(GAME_BIN)):
        core = ctypes.WinDLL(str(GAME_BIN / "fmodex64.dll"))
        library = ctypes.WinDLL(str(GAME_BIN / "fmod_event64.dll"))
    pointer = ctypes.c_void_p
    pointer_ref = ctypes.POINTER(pointer)
    signatures = {
        "FMOD_EventSystem_Create": [pointer_ref],
        "FMOD_EventSystem_GetSystemObject": [pointer, pointer_ref],
        "FMOD_EventSystem_Init": [pointer, ctypes.c_int, ctypes.c_uint, pointer, ctypes.c_uint],
        "FMOD_EventSystem_SetMediaPath": [pointer, ctypes.c_char_p],
        "FMOD_EventSystem_Load": [pointer, ctypes.c_char_p, pointer, pointer_ref],
        "FMOD_EventSystem_GetEvent": [pointer, ctypes.c_char_p, ctypes.c_uint, pointer_ref],
        "FMOD_Event_Start": [pointer],
        "FMOD_Event_Stop": [pointer, ctypes.c_int],
        "FMOD_Event_GetState": [pointer, ctypes.POINTER(ctypes.c_uint)],
        "FMOD_Event_GetChannelGroup": [pointer, pointer_ref],
        "FMOD_EventSystem_Update": [pointer],
        "FMOD_EventSystem_Release": [pointer],
    }
    for name, signature in signatures.items():
        function = getattr(library, name)
        function.argtypes = signature
        function.restype = ctypes.c_int
    core_signatures = {
        "FMOD_ChannelGroup_GetNumChannels": [pointer, ctypes.POINTER(ctypes.c_int)],
        "FMOD_ChannelGroup_GetChannel": [pointer, ctypes.c_int, pointer_ref],
        "FMOD_Channel_GetCurrentSound": [pointer, pointer_ref],
        "FMOD_Channel_GetVolume": [pointer, ctypes.POINTER(ctypes.c_float)],
        "FMOD_ChannelGroup_GetVolume": [pointer, ctypes.POINTER(ctypes.c_float)],
        "FMOD_Sound_GetLength": [pointer, ctypes.POINTER(ctypes.c_uint), ctypes.c_uint],
        "FMOD_Sound_Lock": [
            pointer,
            ctypes.c_uint,
            ctypes.c_uint,
            pointer_ref,
            pointer_ref,
            ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.c_uint),
        ],
        "FMOD_Sound_Unlock": [pointer, pointer, pointer, ctypes.c_uint, ctypes.c_uint],
    }
    for name, signature in core_signatures.items():
        function = getattr(core, name)
        function.argtypes = signature
        function.restype = ctypes.c_int

    def call(name: str, *args: object) -> None:
        assert getattr(library, name)(*args) == 0, name

    system, mixer, project = pointer(), pointer(), pointer()
    call("FMOD_EventSystem_Create", ctypes.byref(system))
    try:
        call("FMOD_EventSystem_GetSystemObject", system, ctypes.byref(mixer))
        core.FMOD_System_SetOutput.argtypes = [pointer, ctypes.c_int]
        # NOSOUND: decode using the installed library without audio devices or a game process.
        assert core.FMOD_System_SetOutput(mixer, 2) == 0
        call("FMOD_EventSystem_Init", system, 64, 0, None, 0)
        call("FMOD_EventSystem_SetMediaPath", system, (ROOT / "sound").as_posix().encode() + b"/")
        call("FMOD_EventSystem_Load", system, f"{BANK}.fev".encode(), None, ctypes.byref(project))
        events = []
        for profile in ("wood", "metal"):
            for cue in DURATIONS:
                if profile == "wood" and cue == "upgrade":
                    continue
                event = pointer()
                call(
                    "FMOD_EventSystem_GetEvent",
                    system,
                    f"{BANK}/{profile}/{cue}".encode(),
                    0,
                    ctypes.byref(event),
                )
                call("FMOD_Event_Start", event)
                call("FMOD_EventSystem_Update", system)
                group, channel, sound = pointer(), pointer(), pointer()
                call("FMOD_Event_GetChannelGroup", event, ctypes.byref(group))
                count = ctypes.c_int()
                assert core.FMOD_ChannelGroup_GetNumChannels(group, ctypes.byref(count)) == 0
                assert count.value == 1, (profile, cue)
                assert core.FMOD_ChannelGroup_GetChannel(group, 0, ctypes.byref(channel)) == 0
                assert core.FMOD_Channel_GetCurrentSound(channel, ctypes.byref(sound)) == 0
                volume = ctypes.c_float()
                assert core.FMOD_Channel_GetVolume(channel, ctypes.byref(volume)) == 0
                assert volume.value > 0
                assert core.FMOD_ChannelGroup_GetVolume(group, ctypes.byref(volume)) == 0
                assert volume.value > 0
                frames = ctypes.c_uint()
                assert core.FMOD_Sound_GetLength(sound, ctypes.byref(frames), 2) == 0
                with wave.open(str(SOURCE / f"{profile}_{cue}.wav"), "rb") as audio:
                    assert frames.value == audio.getnframes(), (profile, cue, frames.value)
                    expected_pcm = audio.readframes(frames.value)
                first, second, first_size, second_size = (
                    pointer(),
                    pointer(),
                    ctypes.c_uint(),
                    ctypes.c_uint(),
                )
                assert (
                    core.FMOD_Sound_Lock(
                        sound,
                        0,
                        len(expected_pcm),
                        ctypes.byref(first),
                        ctypes.byref(second),
                        ctypes.byref(first_size),
                        ctypes.byref(second_size),
                    )
                    == 0
                )
                try:
                    actual_pcm = ctypes.string_at(first, first_size.value)
                    if second_size.value:
                        actual_pcm += ctypes.string_at(second, second_size.value)
                    assert actual_pcm == expected_pcm, (profile, cue)
                finally:
                    assert (
                        core.FMOD_Sound_Unlock(sound, first, second, first_size, second_size) == 0
                    )
                events.append((cue, event))
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            call("FMOD_EventSystem_Update", system)
            time.sleep(0.02)
        for cue, event in events:
            state = ctypes.c_uint()
            call("FMOD_Event_GetState", event, ctypes.byref(state))
            assert bool(state.value & 8) == (cue == "walk_loop"), cue
            call("FMOD_Event_Stop", event, 1)
            call("FMOD_Event_GetState", event, ctypes.byref(state))
            assert state.value & 8 == 0
    finally:
        call("FMOD_EventSystem_Release", system)
