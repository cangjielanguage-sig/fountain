"""xmlconf_gen.py 的自测：SHA-256 分支与 --offline 端到端行为。

运行方式：python3 -m unittest discover -s f_xml/tools -p 'test_*.py' -v
"""

import contextlib
import hashlib
import io
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import xmlconf_gen  # noqa: E402


def sha256_of_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class EnsureSha256Test(unittest.TestCase):
    def test_matching_hash_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "archive.tar.gz")
            payload = b"the real suite bytes"
            with open(path, "wb") as handle:
                handle.write(payload)
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                code = xmlconf_gen.ensure_sha256(path, expected=sha256_of_bytes(payload))
            self.assertEqual(code, 0)
            self.assertEqual(stderr.getvalue(), "")

    def test_mismatch_returns_two_and_reports_both_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "archive.tar.gz")
            payload = b"not the suite"
            with open(path, "wb") as handle:
                handle.write(payload)
            expected = "0" * 64
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                code = xmlconf_gen.ensure_sha256(path, expected=expected)
            self.assertEqual(code, 2)
            message = stderr.getvalue()
            self.assertIn("SHA-256 不匹配", message)
            self.assertIn(expected, message)
            self.assertIn(sha256_of_bytes(payload), message)

    def test_default_expected_is_suite_digest(self):
        self.assertEqual(len(xmlconf_gen.SUITE_SHA256), 64)
        self.assertEqual(xmlconf_gen.ensure_sha256.__defaults__, (xmlconf_gen.SUITE_SHA256,))


class OfflineCorruptedArchiveTest(unittest.TestCase):
    def test_corrupted_cache_aborts_without_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            download_dir = os.path.join(tmp, "download")
            os.makedirs(download_dir)
            archive = os.path.join(download_dir, "xmlts20130923.tar.gz")
            with open(archive, "wb") as handle:
                handle.write(b"corrupted package")

            env = dict(os.environ)
            env["F_XML_XMLCONF_CACHE"] = tmp
            result = subprocess.run(
                [sys.executable, os.path.join(HERE, "xmlconf_gen.py"), "--offline"],
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("SHA-256 不匹配", result.stderr)
            self.assertIn(xmlconf_gen.SUITE_SHA256, result.stderr)
            self.assertIn(sha256_of_bytes(b"corrupted package"), result.stderr)
            self.assertFalse(os.path.exists(os.path.join(tmp, "cases.json")))
            self.assertFalse(os.path.exists(os.path.join(tmp, "unsupported.json")))
            self.assertFalse(os.path.exists(os.path.join(tmp, "suite")))


if __name__ == "__main__":
    unittest.main()
