"""Build a self-contained disk image from an Xcode Release app and a verified asset cache."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
ASSETS = json.loads((ROOT / "distribution/assets.json").read_text())


def run(*args):
    subprocess.run(args, check=True)


def assets_at(cache):
    cache.mkdir(parents=True, exist_ok=True)
    for name, spec in ASSETS.items():
        path = cache / name
        if not path.exists():
            with tempfile.NamedTemporaryFile(dir=cache) as download:
                run("curl", "--proto", "=https", "--proto-redir", "=https", "-fLsS", spec["url"], "-o", download.name)
                if hashlib.sha256(Path(download.name).read_bytes()).hexdigest() != spec["sha256"]:
                    raise ValueError(f"Download checksum mismatch: {name}")
                shutil.copyfile(download.name, path)
        if hashlib.sha256(path.read_bytes()).hexdigest() != spec["sha256"]:
            raise ValueError(f"Cached checksum mismatch: {name}")


def copy_python(archive, engine):
    # Keep the interpreter, its library, and the standard library used by yt-dlp.
    excluded = {"site-packages", "test", "tests", "idlelib", "tkinter", "ensurepip", "turtledemo", "__pycache__"}
    with tarfile.open(archive) as source:
        for entry in source:
            path = Path(entry.name)
            stdlib = path.parts[:3] == ("python", "lib", "python3.13")
            if not entry.isfile() or (not stdlib and str(path) not in ("python/bin/python3.13", "python/lib/libpython3.13.dylib")):
                continue
            if excluded.intersection(path.parts) or any(p.startswith("config-") for p in path.parts):
                continue
            if path.name.startswith(("_tkinter.", "_test")) or path.suffix == ".pyc":
                continue
            target = engine / path
            target.parent.mkdir(exist_ok=True, parents=True)
            with source.extractfile(entry) as reader, target.open("wb") as dest:
                shutil.copyfileobj(reader, dest)
            target.chmod(0o755 if entry.name == "python/bin/python3.13" else 0o644)


def stage(architecture, cache, media, app, stage_dir):
    stage_dir.mkdir(parents=True)
    dest = stage_dir / "Media Utility.app"
    shutil.copytree(app, dest, copy_function=shutil.copyfile)
    main = dest / "Contents/MacOS/YouTubeUtilityApp"
    main.chmod(0o755)
    contents = dest / "Contents"
    plist = contents / "Info.plist"
    info = plistlib.loads(plist.read_bytes())
    info["MediaUtilityBundledEngine"] = True
    plist.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    resources = contents / "Resources"
    engine = resources / "Engine"
    binaries = engine / "bin"
    binaries.mkdir(parents=True)
    triplet = "aarch64" if architecture == "arm64" else "x86_64"
    copy_python(cache / f"cpython-3.13.18+20261110-{triplet}-apple-darwin-install_only_stripped.tar.gz", engine)
    with ZipFile(cache / f"deno-{triplet}-apple-darwin.zip") as source:
        source.extract("deno", binaries)
    for name in ("ffmpeg", "ffprobe"):
        shutil.copyfile(media / "bin" / name, binaries / name)
    for executable in binaries.iterdir():
        executable.chmod(0o755)
    archive = engine / "yt-dlp"
    shutil.copyfile(cache / "yt-dlp", archive)
    archive.chmod(0o755)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != json.loads((resources / "yt-dlp-lock.json").read_text())["sha256"]:
        raise ValueError("Application lock and distribution manifest disagree.")
    licenses = resources / "Licenses"
    licenses.mkdir()
    for name in ASSETS:
        if name.endswith((".md", ".txt")):
            shutil.copyfile(cache / name, licenses / name)
    shutil.copyfile(ROOT / "LICENSE", licenses / "Media-Utility-MIT.txt")
    shutil.copyfile(media / "ffmpeg/COPYING.GPLv2", licenses / "FFmpeg-GPLv2.txt")
    shutil.copyfile(media / "x264/COPYING", licenses / "x264-GPLv2.txt")
    shutil.copyfile(ROOT / "distribution/COMPONENTS.md", licenses / "Components.md")
    run("/usr/bin/tar", "-xf", cache / "python-full.tar.zst", "-C", licenses, "--strip-components", "1", "python/licenses")
    # Preserve vendor signatures and entitlements when provided. Sign every remaining Mach-O.
    for binary in [*binaries.iterdir(), engine / "python/bin/python3.13", *engine.rglob("*.dylib"), *engine.rglob("*.so")]:
        run("lipo", "-verify_arch", architecture, binary)
        verified = subprocess.run(["codesign", "--verify", binary], stderr=subprocess.DEVNULL)
        if verified.returncode:
            run("codesign", "--force", "--timestamp=none", "--sign", "-", binary)
    run("codesign", "--force", "--timestamp=none", "--sign", "-", dest)
    run("codesign", "--verify", "--deep", "--strict", dest)
    (stage_dir / "Applications").symlink_to("/Applications")
    return info["CFBundleShortVersionString"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("arch", choices=("arm64", "x86_64"))
    parser.add_argument("cache", type=Path)
    parser.add_argument("media_build", type=Path)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    assets_at(args.cache)
    args.output.mkdir(exist_ok=True, parents=True)
    stage_dir = args.output / (args.arch + "-image")
    version = stage(args.arch, args.cache, args.media_build, args.app, stage_dir)
    tag = "Apple-Silicon" if args.arch == "arm64" else "Intel"
    image = args.output / f"Media-Utility-{version}-{tag}.dmg"
    run("hdiutil", "create", "-quiet", "-fs", "HFS+", "-volname", "Media Utility",
        "-srcfolder", stage_dir, "-format", "UDZO", image)
    run("hdiutil", "verify", "-quiet", image)


if __name__ == "__main__":
    main()
