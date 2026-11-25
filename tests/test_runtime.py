"""Offline regression checks using synthetic, non-secret session values."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from urllib.request import Request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import download_youtube as media


class RuntimeTests(unittest.TestCase):
    def test_scoped_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp) / "in", Path(tmp) / "out"
            rows = ("# Netscape HTTP Cookie File\n"
                    "#HttpOnly_.youtube.com\tTRUE\t/\tFALSE\t0\tone\tfixture\n"
                    "youtube.com\tFALSE\t/\tTRUE\t0\ttwo\tfixture\n"
                    "other.invalid\tFALSE\t/\tTRUE\t0\tthree\tfixture\n")
            src.write_text(rows)
            media.write_scoped_cookies(src, "www.youtube.com", dst)
            self.assertEqual(dst.read_text().splitlines()[1:], ["#HttpOnly_www.youtube.com\tFALSE\t/\tTRUE\t0\tone\tfixture"])
            self.assertEqual(src.read_text(), rows)
            self.assertEqual(dst.stat().st_mode & 0o777, 0o600)

    def test_site_session_uses_only_its_own_profile_and_cookie_domains(self):
        from unittest.mock import patch
        from http.cookiejar import Cookie
        spec = importlib.util.spec_from_file_location("runtime", ROOT / "YouTubeUtilityApp/downloader_runtime.py")
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
        address = "https://media.example.invalid/watch"
        def cookie(domain, value, shared):
            return Cookie(0, "id", value, None, False, domain, shared, shared, "/", True, True,
                          None, True, None, None, {}, False)
        with tempfile.TemporaryDirectory() as temp, patch.object(Path, "home", return_value=Path(temp)):
            with self.assertRaises(ValueError):
                runtime.site_profile(address)
            token = runtime.hashlib.sha256(b"media.example.invalid:443").hexdigest()
            root = Path(temp) / "Library/Application Support/Media Utility/Site Browsers" / token
            root.mkdir(mode=0o700, parents=True)
            (root / ".media-utility-site").write_text(token)
            alternate = Path(temp) / "unrelated"
            alternate.mkdir()
            (root / "Default").symlink_to(alternate)
            with self.assertRaises(ValueError):
                runtime.site_profile(address)
            (root / "Default").unlink()
            (root / "Default").mkdir()
            self.assertEqual(runtime.site_profile(address), (root / "Default").resolve())
            with self.assertRaises(ValueError):
                runtime.site_profile("https://media.example.invalid:8443/")
            dest = Path(temp) / "session.txt"
            runtime.write_site_session([cookie(".example.invalid", "selected", True),
                                        cookie("example.invalid", "unrelated", False),
                                        cookie("another.invalid", "unrelated", False)], address, dest)
            self.assertEqual(dest.read_text().splitlines()[1:], ["media.example.invalid\tFALSE\t/\tTRUE\t0\tid\tselected"])
            self.assertEqual(dest.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                runtime.write_site_session([cookie("media.example.invalid", "synthetic", False)], address, dest)

    def test_existing_mov_survives_invalid_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "media.mov"
            target.write_bytes(b"original")
            with self.assertRaises(Exception):
                media.convert_to_mov(Path(tmp) / "missing", target, 18, "medium", True)
            self.assertEqual(target.read_bytes(), b"original")

    def test_session_policy_in_isolated_child(self):
        import subprocess
        command = media.yt_dlp_base_command(None)
        archive = command[command.index("-S") + 2]
        subprocess.run([command[0], "-I", "-S", __file__, "--session", archive], check=True)

    def test_runtime_selects_compatible_youtube_player(self):
        import subprocess
        command = media.yt_dlp_base_command(None)
        archive = command[command.index("-S") + 2]
        subprocess.run([command[0], "-I", "-S", "-B", __file__, "--player", archive], check=True)


if __name__ == "__main__" and sys.argv[1:2] == ["--player"]:
    import runpy
    from unittest.mock import patch

    archive = sys.argv[2]
    sys.path.insert(0, archive)
    import yt_dlp
    from yt_dlp.extractor.youtube._video import YoutubeIE

    def check_player(arguments):
        options = yt_dlp.parse_options(arguments).ydl_opts
        with yt_dlp.YoutubeDL(options, auto_init=False) as downloader:
            extractor = YoutubeIE(downloader)
            player_url = extractor._construct_player_url(player_id="deadbeef")
            assert extractor._get_player_id_variant_and_path(player_url)[1] == "tv", player_url

    runtime = ROOT / "YouTubeUtilityApp/downloader_runtime.py"
    argv = [str(runtime), archive, "--ignore-config", "--no-remote-components", "--",
            "https://www.youtube.com/watch?v=abcdefghijk"]
    with patch.object(yt_dlp, "main", side_effect=check_player) as start, patch.object(sys, "argv", argv):
        runpy.run_path(str(runtime), run_name="__main__")
        start.assert_called_once()
elif __name__ == "__main__" and sys.argv[1:2] == ["--session"]:
    archive = sys.argv[2]
    sys.path.insert(0, archive)
    from yt_dlp.cookies import YoutubeDLCookieJar
    spec = importlib.util.spec_from_file_location("media_runtime", ROOT / "YouTubeUtilityApp/downloader_runtime.py")
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    with tempfile.TemporaryDirectory() as temp:
        row = Path(temp) / "fixture"
        row.write_text("# Netscape HTTP Cookie File\nmedia.example.invalid\tFALSE\t/\tTRUE\t0\tselected\tfixture\n")
        runtime.restrict_session("https://media.example.invalid/watch")
        jar = YoutubeDLCookieJar(row)
        jar.load()
        assert jar.get_cookie_header("https://media.example.invalid/video") == "selected=fixture"
        for url in ["http://media.example.invalid/video", "https://child.media.example.invalid/video",
                    "https://media.example.invalid:8443/video", "https://other.invalid/video"]:
            assert not jar.get_cookie_header(url)
        import subprocess
        try:
            subprocess.run(["ffmpeg", "-cookies", "synthetic"], check=False)
        except PermissionError:
            pass
        else:
            raise AssertionError("External network downloader was allowed")
elif __name__ == "__main__":
    unittest.main()
