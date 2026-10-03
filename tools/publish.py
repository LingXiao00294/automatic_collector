"""Clean publish/ and copy the distributable DST mod files without compression."""

from pathlib import Path
from shutil import copy2, rmtree

ROOT = Path(__file__).resolve().parents[1]
FILES = ("modinfo.lua", "modmain.lua", "modicon.xml", "modicon.tex", "README.md", "LICENSE")
TREES = ("scripts", "anim", "images", "sound")


def release_files(root: Path) -> list[Path]:
    """Validate the complete whitelist before removing the previous release."""
    files = [root / name for name in FILES]
    for tree in TREES:
        directory = root / tree
        if not directory.is_dir():
            raise FileNotFoundError(directory)
        files.extend(path for path in directory.rglob("*") if path.is_file())
    for path in files:
        if not path.is_file():
            raise FileNotFoundError(path)
        if not path.resolve().is_relative_to(root):
            raise ValueError(f"Release source is outside the repository: {path}")
    return sorted(files)


def publish(root: Path = ROOT) -> Path:
    root = root.resolve()
    output = root / "publish"
    # Reject a redirected output before recursive deletion, including Windows junctions.
    if output.is_symlink() or output.is_junction() or output.resolve() != output:
        raise ValueError(f"Publish directory must be inside the repository: {output}")
    if output.exists() and not output.is_dir():
        raise NotADirectoryError(output)
    files = release_files(root)
    if output.exists():
        rmtree(output)
    output.mkdir()
    for source in files:
        destination = output / source.relative_to(root)
        destination.parent.mkdir(parents=True, exist_ok=True)
        copy2(source, destination)
    print(f"Published {len(files)} files (uncompressed): {output}")
    return output


if __name__ == "__main__":
    publish()
