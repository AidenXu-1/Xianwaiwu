"""Exercise pinned cache publication and failure preservation without external requests."""
import hashlib
import importlib.util
import io
from pathlib import Path
import ssl
import tempfile
import types
import unittest
from unittest.mock import patch
import urllib.error

path = Path(__file__).resolve().parents[2] / "audio/model_store.py"
spec = importlib.util.spec_from_file_location("model_store", path)
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)

class Response(io.BytesIO):
    def geturl(self): return "https://example.invalid/model.bin"

class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "cache"
        self.data = b"pinned-model-fixture"
        self.item = {"filename": "fixture.bin", "bytes": len(self.data),
                     "sha256": hashlib.sha256(self.data).hexdigest(), "url": "https://example.invalid/model.bin"}
        self.progress = []
        self.addCleanup(patch.stopall)
        patch.dict("sys.modules", {"certifi": types.SimpleNamespace(where=lambda: "fixture-ca")}).start()
        patch.object(ssl, "create_default_context", return_value=None).start()
    def run_fetch(self, response):
        with patch.object(store.urllib.request, "urlopen", return_value=response):
            store.ensure_files([self.item], self.directory, lambda *values: self.progress.append(values))
    def assert_no_partial(self):
        self.assertEqual(list(self.directory.glob(".download-*")), [])
    def test_first_download_verifies_and_publishes(self):
        self.run_fetch(Response(self.data))
        self.assertEqual((self.directory / "fixture.bin").read_bytes(), self.data)
        self.assertEqual(self.progress[-1][:2], (len(self.data), len(self.data)))
        self.assert_no_partial()
    def test_valid_cache_works_without_network(self):
        self.directory.mkdir(); (self.directory / "fixture.bin").write_bytes(self.data)
        with patch.object(store.urllib.request, "urlopen", side_effect=AssertionError("network used")):
            store.ensure_files([self.item], self.directory, lambda *args: None)
    def test_bad_checksum_preserves_existing_file(self):
        self.directory.mkdir(); old = self.directory / "fixture.bin"; old.write_bytes(b"older-cache")
        with self.assertRaises(ValueError): self.run_fetch(Response(b"x" * len(self.data)))
        self.assertEqual(old.read_bytes(), b"older-cache"); self.assert_no_partial()
    def test_too_large_is_bounded_and_not_published(self):
        with self.assertRaises(ValueError): self.run_fetch(Response(self.data + b"overflow"))
        self.assertFalse((self.directory / "fixture.bin").exists()); self.assert_no_partial()
    def test_truncated_download_not_published(self):
        with self.assertRaises(ValueError): self.run_fetch(Response(self.data[:3]))
        self.assertFalse((self.directory / "fixture.bin").exists()); self.assert_no_partial()
    def test_insecure_redirect_is_rejected(self):
        response = Response(self.data); response.geturl = lambda: "http://example.invalid/model.bin"
        with self.assertRaises(ValueError): self.run_fetch(response)
        self.assertFalse((self.directory / "fixture.bin").exists()); self.assert_no_partial()
    def test_unsafe_filename_is_rejected(self):
        self.item["filename"] = "../escape.bin"
        with self.assertRaises(ValueError): self.run_fetch(Response(self.data))
        self.assertFalse((Path(self.temp.name) / "escape.bin").exists())
    def test_symlink_target_is_not_followed(self):
        self.directory.mkdir(); external = Path(self.temp.name) / "personal.bin"; external.write_bytes(b"keep")
        (self.directory / "fixture.bin").symlink_to(external)
        with self.assertRaises(ValueError): self.run_fetch(Response(self.data))
        self.assertEqual(external.read_bytes(), b"keep")
    def test_network_error_is_readable_and_retryable(self):
        with patch.object(store.urllib.request, "urlopen", side_effect=urllib.error.URLError("offline")):
            with self.assertRaisesRegex(ValueError, "联网"):
                store.ensure_files([self.item], self.directory, lambda *args: None)
        self.assert_no_partial()
        self.run_fetch(Response(self.data)); self.assertEqual((self.directory / "fixture.bin").read_bytes(), self.data)
    def test_interruption_cleans_partial(self):
        response = Response(self.data)
        response.read = unittest.mock.Mock(side_effect=[b"part", KeyboardInterrupt()])
        with self.assertRaises(KeyboardInterrupt): self.run_fetch(response)
        self.assertFalse((self.directory / "fixture.bin").exists()); self.assert_no_partial()
    def test_multiple_models_report_total_and_reuse_cache(self):
        second = dict(self.item, filename="second.bin")
        with patch.object(store.urllib.request, "urlopen", side_effect=[Response(self.data), Response(self.data)]):
            store.ensure_files([self.item, second], self.directory, lambda *args: self.progress.append(args))
        self.assertEqual(self.progress[-1][:2], (2 * len(self.data), 2 * len(self.data)))
        self.assert_no_partial()

if __name__ == "__main__": unittest.main(verbosity=2)
