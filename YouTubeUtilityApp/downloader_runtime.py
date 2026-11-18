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


def restrict_session(url):
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

        if "--cookies" in arguments:
            restrict_session(arguments[-1])
        yt_dlp.main(arguments)


if __name__ == "__main__":
    main()
