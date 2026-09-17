#!/usr/bin/env python3
"""Fixture-only checks for shared-package build provenance."""
import importlib.util
import pathlib
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "chat_core_provenance", pathlib.Path(__file__).with_name("chat-core-provenance.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="house-provenance-test-")
        self.root = pathlib.Path(self.temp.name)
        (self.root / "Package.swift").write_text("// fixture\n")
        (self.root / "Sources" / "Core").mkdir(parents=True)
        (self.root / "Sources" / "Core" / "Core.swift").write_text("struct Core {}\n")

    def tearDown(self):
        self.temp.cleanup()

    def test_deterministic_and_sensitive_to_source_bytes(self):
        first = module.source_fingerprint(self.root)
        self.assertEqual(first, module.source_fingerprint(self.root))
        (self.root / "Sources" / "Core" / "Core.swift").write_text("struct Changed {}\n")
        self.assertNotEqual(first, module.source_fingerprint(self.root))

    def test_build_outputs_and_docs_do_not_change_source_identity(self):
        first = module.source_fingerprint(self.root)
        (self.root / ".build").mkdir()
        (self.root / ".build" / "binary").write_bytes(b"compiled")
        (self.root / "README.md").write_text("Documentation only")
        self.assertEqual(first, module.source_fingerprint(self.root))

    def test_source_names_affect_fingerprint(self):
        first = module.source_fingerprint(self.root)
        source = self.root / "Sources" / "Core" / "Core.swift"
        source.rename(source.with_name("Renamed.swift"))
        self.assertNotEqual(first, module.source_fingerprint(self.root))

    def test_symlink_source_is_refused(self):
        source = self.root / "Sources" / "Core" / "Core.swift"
        (source.parent / "Link.swift").symlink_to(source)
        with self.assertRaises(ValueError):
            module.source_fingerprint(self.root)

    def test_missing_package_refused(self):
        with self.assertRaises(ValueError):
            module.source_fingerprint(self.root / "absent")


if __name__ == "__main__":
    unittest.main()
