"""Run the reviewed Unix zipapp with an isolated Python (-I -S)."""
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from urllib.parse import urlsplit


def origin(url):
    parsed = urlsplit(url)
    return parsed.scheme, parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)


def restrict_session(url, deno=None):
    """Apply to the pinned stdlib HTTP transport, including redirects."""
    from yt_dlp.cookies import YoutubeDLCookieJar
    from yt_dlp.networking._urllib import HTTPHandler

    allowed = origin(url)
    if allowed[0] != "https" or not allowed[1]:
        raise ValueError("Session cookies require an HTTPS media URL.")

    class SessionPolicy(http.cookiejar.DefaultCookiePolicy):
        def return_ok(self, cookie, request):
            return origin(request.full_url) == allowed and super().return_ok(cookie, request)

    initialize = YoutubeDLCookieJar.__init__

    def initialize_scoped(jar, *args, **kwargs):
        initialize(jar, *args, **kwargs)
        jar.set_policy(SessionPolicy(strict_ns_domain=SessionPolicy.DomainStrictNonDomain))

    YoutubeDLCookieJar.__init__ = initialize_scoped
    open_request = HTTPHandler.do_open

    def open_scoped(handler, connection, request, **kwargs):
        if origin(request.full_url) != allowed:
            for header in ("Cookie", "Authorization"):
                request.remove_header(header)
        return open_request(handler, connection, request, **kwargs)

    HTTPHandler.do_open = open_scoped

    # Some external downloaders serialize cookies in process arguments. Permit
    # only local FFmpeg postprocessing and version probes in this process.
    def local_helpers(event, args):
        if event != "subprocess.Popen":
            return
        executable, argv, _, _ = args
        if deno and os.fsdecode(executable) == str(deno):
            options = list(argv[1:])
            base = ["run", "--ext=js", "--no-code-cache", "--no-prompt", "--no-remote",
                    "--no-lock", "--node-modules-dir=none", "--no-config"]
            if options in (["--version"], ["-V"], base + ["--no-npm", "--cached-only", "-"]):
                return
            raise PermissionError("Only the bundled offline JavaScript solver is available.")
        if Path(os.fsdecode(executable)).name not in {"ffmpeg", "ffprobe"}:
            raise PermissionError("External helpers are disabled for signed-in downloads.")
        for index, argument in enumerate(argv):
            arg = os.fsdecode(argument)
            if arg in {"-cookies", "-headers"} or "://" in arg:
                raise PermissionError("This format requires an external network downloader.")
            if arg == "-i":
                source = os.fsdecode(argv[index + 1]).removeprefix("file:")
                if not Path(source).is_file():
                    raise PermissionError("Signed-in postprocessing requires a local file.")

    sys.addaudithook(local_helpers)


def site_profile(url):
    """Resolve only the separate profile created by the app for this origin."""
    scheme, host, port = origin(url)
    parsed = urlsplit(url)
    if scheme != "https" or not host or parsed.username is not None or parsed.password is not None:
        raise ValueError("A secure site address is required.")
    token = hashlib.sha256(f"{host}:{port}".encode()).hexdigest()
    support = (Path.home() / "Library/Application Support").resolve()
    root = support / "Media Utility/Site Browsers" / token
    profile = root / "Default"
    marker = root / ".media-utility-site"
    if (profile.resolve() != profile or not profile.is_dir() or marker.is_symlink()
            or not marker.is_file() or marker.read_bytes() != token.encode()
            or root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o077):
        raise ValueError("The separate site profile is unavailable.")
    return profile


def write_site_session(cookies, url, target):
    host = urlsplit(url).hostname
    rows = ["# Netscape HTTP Cookie File"]
    for cookie in cookies:
        domain = cookie.domain.lower().lstrip(".")
        if not domain or not (host == domain or (cookie.domain_specified and host.endswith("." + domain))):
            continue
        if cookie.is_expired() or not cookie.name or not cookie.path.startswith("/"):
            continue
        fields = [cookie.path, cookie.name, cookie.value]
        if any(not isinstance(field, str) or any(ord(c) < 32 or ord(c) == 127 for c in field) for field in fields):
            continue
        label = "#HttpOnly_" if cookie.has_nonstandard_attr("HttpOnly") else ""
        rows.append("\t".join([label + host, "FALSE", cookie.path, "TRUE", str(cookie.expires or 0),
                                cookie.name, cookie.value]))
    if len(rows) == 1:
        raise ValueError("The site session is empty.")
    fd = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write("\n".join(rows) + "\n")


def main():
    archive = Path(sys.argv[1])
    arguments = sys.argv[2:]
    lock = json.loads(Path(__file__).with_name("yt-dlp-lock.json").read_text())
    with archive.open("rb") as handle:
        payload = handle.read(16 * 1024 * 1024 + 1)
    if hashlib.sha256(payload).hexdigest() != lock["sha256"]:
        raise ValueError("Downloader checksum mismatch. Run script/install-tools.sh.")
    # Import the same bytes that passed verification, even if the installation changes.
    with TemporaryDirectory(prefix="media-utility-engine-") as work:
        verified = Path(work) / "yt-dlp.zip"
        verified.write_bytes(payload)
        sys.path.insert(0, str(verified))
        import yt_dlp

        if arguments[:1] == ["--site-session"] and len(arguments) == 3:
            from yt_dlp.cookies import extract_cookies_from_browser
            try:
                profile = site_profile(arguments[1])
                # The official importer accepts an absolute profile and never searches other profiles.
                cookies = extract_cookies_from_browser("chrome", profile=str(profile))
                write_site_session(cookies, arguments[1], arguments[2])
            except Exception:
                sys.exit("The site session could not be prepared.")
            return
        if "--cookies" in arguments:
            deno = Path(__file__).parent / "Engine/bin/deno"
            restrict_session(arguments[-1], deno if deno.is_file() else None)
        yt_dlp.main(arguments)


if __name__ == "__main__":
    main()
