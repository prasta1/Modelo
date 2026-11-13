import io
import unittest
import urllib.error
import xml.etree.ElementTree as ET
from unittest.mock import patch

from check_update_version import check_version

URL = "https://example.com/appcast.xml"


def feed(*versions):
    items = "".join(f"<item><sparkle:version>{version}</sparkle:version></item>" for version in versions)
    return (
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
        f"<channel>{items}</channel></rss>"
    ).encode()


class UpdateVersionTests(unittest.TestCase):
    def check(self, current, document):
        with patch("urllib.request.urlopen", return_value=io.BytesIO(document)) as request:
            check_version(current, URL)
            request.assert_called_once_with(URL, timeout=30)

    def test_newer_build(self):
        self.check("10", feed("8", "9"))

    def test_equal_or_older_build(self):
        for current in ("8", "9"):
            with self.subTest(current=current), self.assertRaises(ValueError):
                self.check(current, feed("9", "7"))

    def test_invalid_builds(self):
        for value in ("", "-1", "0", "1.2", "abc"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.check(value, feed("1"))
            with self.subTest(previous=value), self.assertRaises(ValueError):
                self.check("2", feed(value))

    def test_missing_or_malformed_feed(self):
        for document in (b"not XML", b"<rss/>", feed()):
            with self.subTest(document=document), self.assertRaises((ValueError, ET.ParseError)):
                self.check("2", document)

    def test_first_release(self):
        error = urllib.error.HTTPError(URL, 404, "Not found", {}, None)
        with patch("urllib.request.urlopen", side_effect=error):
            check_version("1", URL)

    def test_network_failures_are_not_first_releases(self):
        for error in (
            urllib.error.HTTPError(URL, 403, "Forbidden", {}, None),
            urllib.error.HTTPError(URL, 500, "Server error", {}, None),
            urllib.error.URLError("Offline"),
            TimeoutError("Timed out"),
        ):
            with self.subTest(error=error), patch("urllib.request.urlopen", side_effect=error):
                with self.assertRaises(OSError):
                    check_version("2", URL)


if __name__ == "__main__":
    unittest.main()
