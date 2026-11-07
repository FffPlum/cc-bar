import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "validate_release", Path(__file__).resolve().parents[1] / "validate-release.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseInputsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "ccbar.xcodeproj").mkdir()
        (self.root / "release-notes").mkdir()
        self.project = self.root / "ccbar.xcodeproj/project.pbxproj"
        self.write_versions(["2.0.0", "2.0.0"])
        self.notes = self.root / "release-notes/v2.0.0.md"
        self.notes.write_text("## 本版亮点\n\n- React 主窗口。\n")

    def write_versions(self, versions):
        self.project.write_text("\n".join(
            "buildSettings = {\nPRODUCT_BUNDLE_IDENTIFIER = com.fffplum.ccbar;\n"
            f"MARKETING_VERSION = {version};\n}};" for version in versions
        ))

    def test_branch_validation_does_not_require_unwritten_release_notes(self):
        self.notes.unlink()
        self.assertEqual(module.validate(self.root), "2.0.0")

    def test_valid_release(self):
        self.assertEqual(module.validate(self.root, "v2.0.0"), "2.0.0")

    def test_both_configurations_must_match(self):
        for versions in (
            ["2.0.0"], ["2.0.0", "1.9.9"], ["2.0", "2.0"],
        ):
            with self.subTest(versions=versions):
                self.write_versions(versions)
                with self.assertRaises(ValueError):
                    module.validate(self.root, "v2.0.0")

    def test_test_bundle_version_does_not_affect_app_release(self):
        with self.project.open("a") as project:
            project.write("\nbuildSettings = {\nPRODUCT_BUNDLE_IDENTIFIER = com.fffplum.ccbarTests;\nMARKETING_VERSION = 1.0;\n};\n")
        self.assertEqual(module.validate(self.root, "v2.0.0"), "2.0.0")

    def test_invalid_or_mismatched_tag_is_rejected(self):
        for tag in ("v2.0.1", "2.0.0", "v02.0.0", "v2.0.0-beta", "../v2.0.0"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                module.validate(self.root, tag)

    def test_missing_or_invisible_notes_are_rejected(self):
        for content in ("", " \n\t", "<!-- release notes go here -->\n"):
            with self.subTest(content=content):
                self.notes.write_text(content)
                with self.assertRaises(ValueError):
                    module.validate(self.root, "v2.0.0")
        self.notes.unlink()
        with self.assertRaises(ValueError):
            module.validate(self.root, "v2.0.0")

    def test_signing_validation_accepts_both_sparkle_key_formats(self):
        for size in (32, 96):
            module.validate_signing({
                "SPARKLE_PUBLIC_ED_KEY": base64.b64encode(bytes(32)).decode(),
                "SPARKLE_PRIVATE_ED_KEY": base64.b64encode(bytes(size)).decode(),
            })

    def test_signing_errors_do_not_echo_key_material(self):
        invalid_secret = "not-a-real-secret-to-echo"
        with self.assertRaises(ValueError) as error:
            module.validate_signing({
                "SPARKLE_PUBLIC_ED_KEY": base64.b64encode(bytes(32)).decode(),
                "SPARKLE_PRIVATE_ED_KEY": invalid_secret,
            })
        self.assertNotIn(invalid_secret, str(error.exception))
        with self.assertRaises(ValueError):
            module.validate_signing({})


if __name__ == "__main__":
    unittest.main()
