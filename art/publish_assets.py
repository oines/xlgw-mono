#!/usr/bin/env python3
"""Publish an immutable companion bundle into HARBOR_COMPANION_DIR."""
import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import shutil
from tempfile import TemporaryDirectory

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("release")
parser.add_argument("--from", dest="source", type=Path,
                    default=Path(__file__).resolve().parents[1] / "apps/mobile/assets/companion")
args = parser.parse_args()
if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,79}", args.release):
    parser.error("release must be a lowercase version, for example pets-20261114.1")
args.directory.mkdir(parents=True, exist_ok=True)
target = args.directory / args.release
if target.exists():
    parser.error("choose a new release name; published versions are immutable")
allowed = {".glb", ".vrm", ".png", ".webp", ".jpg", ".jpeg"}
assets = sorted(p for p in args.source.rglob("*") if p.is_file() and p.suffix in allowed)
if not (args.source / "companion.glb").is_file() or not 1 <= len(assets) <= 64:
    parser.error("expected companion.glb and at most 64 model/image files")
if sum(p.stat().st_size for p in assets) > 100 * 1024**2:
    parser.error("bundle is larger than 100 MiB")
with TemporaryDirectory(prefix=".incoming-", dir=args.directory) as temporary:
    staging = Path(temporary) / "bundle"
    staging.mkdir()
    files = []
    for path in assets:
        name = path.relative_to(args.source)
        if len(name.as_posix()) > 120 or any(not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", part) for part in name.parts):
            parser.error(f"invalid asset path: {name}")
        if not 0 < path.stat().st_size <= 64 * 1024**2:
            parser.error(f"invalid asset size: {name}")
        local = staging / name
        local.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, local)
        with local.open("rb") as source:
            digest = sha256()
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        files.append({"path": name.as_posix(), "size": local.stat().st_size, "sha256": digest.hexdigest()})
    manifest = {"release": args.release, "version": 1, "files": files}
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    staging.rename(target)
    pointer = Path(temporary) / "current"
    pointer.write_text(args.release + "\n", encoding="utf-8")
    pointer.replace(args.directory / "current")
print(target)
