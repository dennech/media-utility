#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import re
import time
from tempfile import TemporaryDirectory
from functools import lru_cache
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


MOV_COMPATIBLE_VIDEO_CODECS = {"h264", "hevc", "prores", "mpeg4"}
MOV_COMPATIBLE_AUDIO_CODECS = {
    "aac",
    "alac",
    "pcm_s16le",
    "pcm_s24le",
    "pcm_s32le",
    "pcm_f32le",
}
STREAMING_PROTOCOLS = {"m3u8", "m3u8_native"}
COOKIE_FILE_MAX_BYTES = 10 * 1024 * 1024


@dataclass
class FormatChoice:
    format_id: str
    acodec: str
    abr: float
    asr: int


@dataclass
class VideoChoice:
    format_id: str
    vcodec: str
    width: int
    height: int
    fps: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Download YouTube videos with an explicit audio policy and convert the result "
            "to a Finder-friendly MOV when requested."
        )
    )
    parser.add_argument("urls", nargs="+", help="YouTube video URLs to download.")
    parser.add_argument(
        "--cookies", type=Path, help="Netscape export. Only current cookies for each HTTPS host are used."
    )
    parser.add_argument(
        "--audio-policy",
        choices=("aac-first", "best"),
        default="aac-first",
        help="Audio selection policy. 'aac-first' prefers AAC even if Opus exists.",
    )
    parser.add_argument(
        "--output-container",
        choices=("mov", "mkv"),
        default="mov",
        help="Final output container.",
    )
    parser.add_argument(
        "--output-dir",
        default=".",
        help="Directory where finished files will be written.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing final files.",
    )
    parser.add_argument(
        "--keep-intermediate",
        action="store_true",
        help="Keep the temporary merged source file created by yt-dlp.",
    )
    parser.add_argument(
        "--crf",
        type=int,
        default=18,
        help="CRF for H.264 transcoding when MOV-compatible remux is not possible.",
    )
    parser.add_argument(
        "--preset",
        default="medium",
        help="ffmpeg preset for H.264 transcoding.",
    )
    return parser.parse_args()


@lru_cache
def brew_tool(name: str, formula: str) -> Path:
    for prefix in (Path("/opt/homebrew"), Path("/usr/local")):
        path = (prefix / "bin" / name).resolve()
        if not path.is_relative_to(prefix / "Cellar") or not os.access(path, os.X_OK):
            continue
        parts = path.relative_to(prefix / "Cellar").parts
        if len(parts) < 4 or parts[0].split("@")[0] != formula:
            continue
        if name == "python3" and path.name.startswith("python3"):
            return path
        if parts[2:] == ("bin", name):
            return path
    raise ValueError(f"Install {formula} with Homebrew to provide {name}.")


def run_command(command: list[str], capture_output: bool = False) -> subprocess.CompletedProcess[str]:
    if command[0] in {"ffmpeg", "ffprobe"}:
        command = [str(brew_tool(command[0], "ffmpeg")), *command[1:]]
    env = {key: os.environ[key] for key in ("HOME", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    return subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE if capture_output else subprocess.DEVNULL,
                          stderr=subprocess.PIPE if capture_output else subprocess.DEVNULL, env=env)


def media_host(url: str, authenticated: bool = False) -> str:
    parsed = urlsplit(url)
    schemes = {"https"} if authenticated else {"http", "https"}
    if parsed.scheme not in schemes or not parsed.hostname or parsed.username is not None or parsed.password is not None:
        raise ValueError("Use an HTTP(S) media URL without embedded credentials. Cookies require HTTPS.")
    return parsed.hostname.lower()


# Generic hosts require an exact match. These known parent domains may cover subdomains.
COOKIE_PARENTS = frozenset(
    "youtube.com youtu.be vimeo.com dailymotion.com dai.ly twitch.tv tiktok.com instagram.com "
    "facebook.com fb.watch twitter.com x.com vk.com vkvideo.ru rutube.ru soundcloud.com".split()
)


def write_scoped_cookies(source: Path, host: str, destination: Path) -> None:
    source = source.expanduser()
    if not source.is_file() or source.stat().st_size > COOKIE_FILE_MAX_BYTES:
        raise ValueError("Choose a Netscape cookie file smaller than 10 MB.")
    with source.open("rb") as handle:
        data = handle.read(COOKIE_FILE_MAX_BYTES + 1)
    if len(data) > COOKIE_FILE_MAX_BYTES:
        raise ValueError("Cookie export is too large.")
    rows = ["# Netscape HTTP Cookie File"]
    for line in data.decode("utf-8").splitlines():
        http_only = line.startswith("#HttpOnly_")
        if not line or (line.startswith("#") and not http_only):
            continue
        fields = line.removeprefix("#HttpOnly_").split("\t")
        if (len(fields) != 7 or fields[1] not in {"TRUE", "FALSE"} or fields[3] not in {"TRUE", "FALSE"}
                or not fields[2].startswith("/") or not fields[5]):
            raise ValueError("Invalid Netscape cookie row.")
        domain = fields[0].lower().lstrip(".")
        if host != domain and not (fields[1] == "TRUE" and domain in COOKIE_PARENTS and host.endswith("." + domain)):
            continue
        if fields[4] and not fields[4].isdecimal():
            raise ValueError("Invalid cookie expiry.")
        expiry = int(fields[4] or 0)
        if expiry and expiry <= time.time():
            continue
        fields[0] = ("#HttpOnly_" if http_only else "") + host
        fields[1], fields[3], fields[4] = "FALSE", "TRUE", str(expiry)
        rows.append("\t".join(fields))
    if len(rows) == 1:
        raise ValueError("No current cookies matched " + host + ". Use the full HTTPS media URL.")
    with os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as handle:
        handle.write("\n".join(rows) + "\n")


def yt_dlp_base_command(cookies_file: Path | None) -> list[str]:
    lock_path = Path(__file__).resolve().parent / "YouTubeUtilityApp" / "yt-dlp-lock.json"
    lock = json.loads(lock_path.read_text())
    archive = Path.home() / "Library/Application Support/Media Utility/tools" / lock["version"] / "yt-dlp"
    if (not archive.is_file() or archive.stat().st_size > 16 * 1024 * 1024
            or hashlib.sha256(archive.read_bytes()).hexdigest() != lock["sha256"]):
        raise ValueError("Install the verified downloader with ./script/install-tools.sh.")
    ffmpeg_dir = brew_tool("ffmpeg", "ffmpeg").parent
    if brew_tool("ffprobe", "ffmpeg").parent != ffmpeg_dir:
        raise ValueError("Install ffmpeg and ffprobe from the same package.")
    command = [str(brew_tool("python3", "python")), "-I", "-S", str(lock_path.with_name("downloader_runtime.py")), str(archive),
               "--ignore-config", "--no-plugin-dirs", "--no-remote-components", "--no-js-runtimes", "--no-cache-dir",
               "--no-playlist", "--ffmpeg-location", str(ffmpeg_dir)]
    if cookies_file:
        command.extend(["--downloader", "native", "--cookies", str(cookies_file)])
    else:
        try:
            deno = brew_tool("deno", "deno")
        except ValueError:
            pass
        else:
            command.extend(["--js-runtimes", "deno:" + str(deno)])
    return command


def load_metadata(url: str, cookies_file: Path | None) -> dict[str, Any]:
    completed = run_command(yt_dlp_base_command(cookies_file) + ["-J", "--", url], capture_output=True)
    return json.loads(completed.stdout)


def clean_name(value: str) -> str:
    value = re.sub(r"^\[\s*([^\]]+?)\s*\]\s*", r"\1 - ", value)
    value = re.sub(r"\[\s*([^\]]+?)\s*\]", r"\1", value)
    value = value.replace("|", " - ")
    value = value.replace(":", " -")
    value = re.sub(r"\s+_\s+", " - ", value)
    value = re.sub(r'[<>"/\\|?*\x00-\x1f]', "", value)
    value = re.sub(r"\s*-\s*", " - ", value)
    value = re.sub(r"\s+", " ", value).strip(" .")
    if not value:
        return "video"
    return value[:180]


def is_audio_only_format(fmt: dict[str, Any]) -> bool:
    if fmt.get("vcodec") != "none":
        return False
    if fmt.get("acodec") not in (None, "none"):
        return True
    format_note = str(fmt.get("format_note") or "").lower()
    return bool(fmt.get("abr") or fmt.get("asr") or "audio" in format_note)


def pick_audio_format(formats: list[dict[str, Any]], policy: str) -> FormatChoice:
    candidates = [fmt for fmt in formats if is_audio_only_format(fmt) and fmt.get("format_id")]
    if not candidates:
        raise RuntimeError("No audio-only formats were found for this video.")

    if policy == "aac-first":
        preferred = [fmt for fmt in candidates if str(fmt.get("acodec", "")).startswith("mp4a")]
        pool = preferred or candidates
    else:
        pool = candidates

    def rank(fmt: dict[str, Any]) -> tuple[int, float, int, float]:
        protocol_score = 0 if fmt.get("protocol") in STREAMING_PROTOCOLS else 1
        abr = float(fmt.get("abr") or fmt.get("tbr") or 0.0)
        asr = int(fmt.get("asr") or 0)
        size = float(fmt.get("filesize") or fmt.get("filesize_approx") or 0.0)
        return (protocol_score, abr, asr, size)

    chosen = max(pool, key=rank)
    return FormatChoice(
        format_id=str(chosen["format_id"]),
        acodec=str(chosen.get("acodec") or "unknown"),
        abr=float(chosen.get("abr") or chosen.get("tbr") or 0.0),
        asr=int(chosen.get("asr") or 0),
    )


def pick_video_format(formats: list[dict[str, Any]]) -> VideoChoice:
    candidates = [
        fmt
        for fmt in formats
        if fmt.get("vcodec") not in (None, "none")
        and fmt.get("acodec") == "none"
        and fmt.get("format_id")
    ]
    if not candidates:
        raise RuntimeError("No video-only formats were found for this video.")

    def rank(fmt: dict[str, Any]) -> tuple[int, int, int, float, float]:
        protocol_score = 0 if fmt.get("protocol") in STREAMING_PROTOCOLS else 1
        height = int(fmt.get("height") or 0)
        width = int(fmt.get("width") or 0)
        fps = float(fmt.get("fps") or 0.0)
        bitrate = float(fmt.get("tbr") or fmt.get("vbr") or 0.0)
        return (protocol_score, height, width, fps, bitrate)

    chosen = max(candidates, key=rank)
    return VideoChoice(
        format_id=str(chosen["format_id"]),
        vcodec=str(chosen.get("vcodec") or "unknown"),
        width=int(chosen.get("width") or 0),
        height=int(chosen.get("height") or 0),
        fps=float(chosen.get("fps") or 0.0),
    )


def download_source(
    url: str,
    metadata: dict[str, Any],
    cookies_file: Path | None,
    audio_policy: str,
    output_dir: Path,
) -> Path:
    formats = metadata.get("formats") or []
    split_video = any(f.get("vcodec") not in (None, "none") and f.get("acodec") == "none" for f in formats)
    if split_video and any(is_audio_only_format(f) for f in formats):
        video = pick_video_format(formats)
        audio = pick_audio_format(formats, audio_policy)
        selector = f"{video.format_id}+{audio.format_id}"
    else:
        # yt-dlp ranks formats from worst to best, including direct media URLs.
        combined = [f for f in formats if f.get("format_id") and f.get("vcodec") != "none"
                    and f.get("acodec") != "none" and (f.get("vcodec") or f.get("ext") in
                    {"mp4", "mov", "mkv", "webm", "m4v"})]
        if not combined:
            raise ValueError("No format with both video and audio was found.")
        selector = combined[-1]["format_id"]
    temp_path = output_dir / "download.source.mkv"
    command = yt_dlp_base_command(cookies_file) + [
        "-f",
        selector,
        "--merge-output-format", "mkv",
        "--remux-video", "mkv",
        "-o",
        str(temp_path.parent).replace("%", "%%") + "/download.source.%(ext)s",
        "--", url,
    ]

    print("Downloading selected media streams…")
    run_command(command)

    if not temp_path.exists():
        raise FileNotFoundError(f"yt-dlp reported success, but {temp_path} was not created.")
    return temp_path


def probe_streams(path: Path) -> dict[str, Any]:
    command = [
        "ffprobe",
        "-v",
        "error",
        "-show_streams",
        "-of",
        "json",
        str(path),
    ]
    completed = run_command(command, capture_output=True)
    return json.loads(completed.stdout)


def convert_to_mov(source_path: Path, output_path: Path, crf: int, preset: str, force: bool) -> None:
    if output_path.exists() and not force:
        raise FileExistsError("The destination already exists.")
    with TemporaryDirectory(dir=output_path.parent, prefix=".media-utility-") as work:
        staged = Path(work) / "output.mov"
        encode_mov(source_path, staged, crf, preset)
        publish(staged, output_path, force)


def encode_mov(source_path: Path, output_path: Path, crf: int, preset: str) -> None:
    streams = probe_streams(source_path).get("streams") or []
    video_stream = next((stream for stream in streams if stream.get("codec_type") == "video"), None)
    audio_stream = next((stream for stream in streams if stream.get("codec_type") == "audio"), None)
    if not video_stream or not audio_stream:
        raise RuntimeError(f"Could not find both video and audio streams in {source_path}")

    video_codec = str(video_stream.get("codec_name") or "")
    audio_codec = str(audio_stream.get("codec_name") or "")
    can_copy = (
        video_codec in MOV_COMPATIBLE_VIDEO_CODECS and audio_codec in MOV_COMPATIBLE_AUDIO_CODECS
    )

    if can_copy:
        command = [
            "ffmpeg",
            "-y",
            "-i",
            str(source_path),
            "-c",
            "copy",
            "-movflags",
            "+faststart",
            str(output_path),
        ]
        print(f"Remuxing to MOV without re-encoding: {output_path.name}")
    else:
        command = [
            "ffmpeg",
            "-y",
            "-i",
            str(source_path),
            "-map",
            "0",
            "-c:v",
            "libx264",
            "-preset",
            preset,
            "-crf",
            str(crf),
            "-pix_fmt",
            "yuv420p",
        ]
        if audio_codec in MOV_COMPATIBLE_AUDIO_CODECS:
            command.extend(["-c:a", "copy"])
        else:
            command.extend(["-c:a", "aac", "-b:a", "192k"])
        command.extend(["-movflags", "+faststart", str(output_path)])
        print(
            f"Transcoding video for MOV compatibility ({video_codec} -> h264), output: "
            f"{output_path.name}"
        )

    run_command(command)


def publish(staged: Path, destination: Path, force: bool) -> None:
    if staged.stat().st_size == 0:
        raise ValueError("The converter produced an empty file.")
    if force:
        os.replace(staged, destination)
    else:
        # macOS RENAME_EXCL also works on volumes without hard links.
        rename = ctypes.CDLL(None, use_errno=True).renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        if rename(os.fsencode(staged), os.fsencode(destination), 4) != 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code))


def main() -> int:
    args = parse_args()
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    failed = False
    for url in args.urls:
        host = "Media URL"
        try:
            host = media_host(url, bool(args.cookies))
            with TemporaryDirectory(dir=output_dir, prefix=".media-utility-") as work, TemporaryDirectory() as sessions:
                cookies = None
                if args.cookies:
                    cookies = Path(sessions) / "session.txt"
                    write_scoped_cookies(args.cookies, host, cookies)
                metadata = load_metadata(url, cookies)
                stem = clean_name(str(metadata.get("title") or metadata.get("id") or "video"))
                final_path = output_dir / f"{stem}.{args.output_container}"
                if final_path.exists() and not args.force:
                    raise FileExistsError("The destination already exists.")
                source = download_source(url, metadata, cookies, args.audio_policy, Path(work))
                if args.output_container == "mov":
                    intermediate = output_dir / f"{stem}.source.mkv"
                    if args.keep_intermediate and intermediate.exists() and not args.force:
                        raise FileExistsError("The intermediate file already exists.")
                    convert_to_mov(source, final_path, args.crf, args.preset, args.force)
                    if args.keep_intermediate:
                        publish(source, intermediate, args.force)
                else:
                    publish(source, final_path, args.force)
                print(f"Saved: {final_path.name}")
        except subprocess.CalledProcessError as error:
            failed = True
            print(f"{host}: media tool exited with status {error.returncode}.", file=sys.stderr)
        except (OSError, ValueError, RuntimeError) as error:
            failed = True
            print(f"{host}: {error.strerror if isinstance(error, OSError) and error.strerror else error}", file=sys.stderr)
    return int(failed)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as error:
        sys.exit(str(error))
