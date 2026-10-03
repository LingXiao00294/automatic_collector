"""Check clean releases and preserve the previous output when preflight fails."""

from pathlib import Path

import pytest

from tools.publish import publish


@pytest.fixture
def repository(tmp_path: Path) -> Path:
    content = {
        "modinfo.lua": 'version = "0.4.0"',
        "modmain.lua": "PrefabFiles = {}",
        "modicon.xml": "<Atlas />",
        "modicon.tex": "KTEX",
        "preview.jpg": "Workshop cover image",
        "README.md": "Installation instructions",
        "LICENSE": "MIT",
        "scripts/components/ac_worker.lua": "return {}",
        "anim/automatic_collector.zip": "Existing engine animation archive",
        "anim/automatic_collector_mk2.zip": "Upgraded engine animation archive",
        "anim/ac_upgrade_kit.zip": "Kit engine animation archive",
        "scripts/prefabs/ac_upgrade_kit.lua": "return {}",
        "images/inventoryimages/automatic_collector.tex": "KTEX",
        "images/inventoryimages/ac_upgrade_kit.tex": "KTEX kit",
        "images/map_icons/automatic_collector_mk2.tex": "KTEX upgraded map icon",
        "sound/ac_collector.fsb": "Original collector audio samples",
        "sound/ac_collector.fev": "Original collector audio events",
        "docs/API.md": "Must not ship",
        "docs/engine.log": "Must not ship",
        "docs/notes.txt": "Must not ship",
        "tests/private.lua": "Must not ship",
        "assets/source/body_front.png": "Must not ship",
        ".runtime/test_world/save": "Must not ship",
    }
    for name, text in content.items():
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return tmp_path


def test_publish_copies_only_release_files(repository: Path):
    output = publish(repository)
    expected = {
        "modinfo.lua",
        "modmain.lua",
        "modicon.xml",
        "modicon.tex",
        "preview.jpg",
        "README.md",
        "LICENSE",
        "scripts/components/ac_worker.lua",
        "anim/automatic_collector.zip",
        "anim/automatic_collector_mk2.zip",
        "anim/ac_upgrade_kit.zip",
        "scripts/prefabs/ac_upgrade_kit.lua",
        "images/inventoryimages/automatic_collector.tex",
        "images/inventoryimages/ac_upgrade_kit.tex",
        "images/map_icons/automatic_collector_mk2.tex",
        "sound/ac_collector.fsb",
        "sound/ac_collector.fev",
    }
    actual = {path.relative_to(output).as_posix() for path in output.rglob("*") if path.is_file()}
    assert actual == expected
    for name in expected:
        assert (output / name).read_bytes() == (repository / name).read_bytes()
    assert not (repository / "dist").exists()
    assert not list(output.glob("*.zip"))
    assert not (output / "docs").exists()


def test_publish_removes_stale_files(repository: Path):
    output = publish(repository)
    stale = output / "scripts/obsolete/old.lua"
    stale.parent.mkdir(parents=True)
    stale.write_text("Obsolete", encoding="utf-8")
    legacy_docs = output / "docs"
    legacy_docs.mkdir()
    (legacy_docs / "API.md").write_text("Old release documentation", encoding="utf-8")
    (repository / "modmain.lua").write_text("Updated", encoding="utf-8")
    publish(repository)
    assert not stale.exists()
    assert not legacy_docs.exists()
    assert (output / "modmain.lua").read_text(encoding="utf-8") == "Updated"


@pytest.mark.parametrize("missing_source", ["modmain.lua", "preview.jpg"])
def test_missing_source_preserves_previous_release(repository: Path, missing_source: str):
    output = publish(repository)
    previous = (output / "modmain.lua").read_bytes()
    previous_preview = (output / "preview.jpg").read_bytes()
    (repository / missing_source).unlink()
    with pytest.raises(FileNotFoundError):
        publish(repository)
    assert (output / "modmain.lua").read_bytes() == previous
    assert (output / "preview.jpg").read_bytes() == previous_preview


def test_publish_rejects_output_file(repository: Path):
    output = repository / "publish"
    output.write_text("Keep this file", encoding="utf-8")
    with pytest.raises(NotADirectoryError):
        publish(repository)
    assert output.read_text(encoding="utf-8") == "Keep this file"
