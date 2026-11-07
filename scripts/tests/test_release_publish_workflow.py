"""Exercise the actual publish shell step against the GitHub draft-release contract."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
STEP_NAME = "Verify uploaded assets before making the release visible"
RELEASE_ID = 123456
REPOSITORY = "example/cc-bar"
TAG = "v2.0.0"


def publish_step_script():
    lines = (ROOT / ".github/workflows/release.yml").read_text().splitlines()
    start = next(index for index, line in enumerate(lines)
                 if line.strip() == f"- name: {STEP_NAME}")
    step_indent = len(lines[start]) - len(lines[start].lstrip())
    run = next(index for index in range(start + 1, len(lines))
               if lines[index].strip() == "run: |")
    run_indent = len(lines[run]) - len(lines[run].lstrip())
    body = []
    for line in lines[run + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= run_indent:
            break
        body.append(line)
    if run_indent <= step_indent or not body:
        raise AssertionError("The release publish step must contain a literal shell block")
    return textwrap.dedent("\n".join(body)) + "\n"


# This fake models GitHub's API behavior, including the regression: drafts cannot
# be fetched by REST tag, although gh release view can resolve their database ID.
FAKE_GH = r'''
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
fixture = json.loads(Path(os.environ["CCBAR_TEST_RELEASE_FIXTURE"]).read_text())
with Path(os.environ["CCBAR_TEST_GH_CALLS"]).open("a") as output:
    output.write(json.dumps(args) + "\n")

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

if args[:2] == ["release", "view"]:
    if args[2] != fixture["tag"] or args[args.index("--repo") + 1] != fixture["repository"]:
        fail("Unexpected release lookup")
    fields = {
        "databaseId": fixture["id"],
        "id": "RE_non_numeric_graphql_node_id",
        "apiUrl": "https://api.github.com/" + fixture["endpoint"],
        "isDraft": True,
        "tagName": fixture["tag"],
    }
    if "--jq" in args or "-q" in args:
        flag = "--jq" if "--jq" in args else "-q"
        if args[args.index(flag) + 1] != ".databaseId":
            fail("Unexpected release JSON query")
        print(fields["databaseId"])
    else:
        requested = args[args.index("--json") + 1].split(",")
        print(json.dumps({key: fields[key] for key in requested}))
    raise SystemExit(0)

if not args or args[0] != "api":
    fail("Unexpected gh command")

method, endpoint, payload = "GET", None, {}
index = 1
while index < len(args):
    arg = args[index]
    if arg in ("--method", "-X", "--field", "-F", "--raw-field", "-f", "--header", "-H"):
        value = args[index + 1]
        if arg in ("--method", "-X"):
            method = value
        elif arg in ("--field", "-F", "--raw-field", "-f"):
            key, value = value.split("=", 1)
            if arg in ("--field", "-F"):
                try:
                    value = json.loads(value)
                except json.JSONDecodeError:
                    pass
            payload[key] = value
        index += 2
    elif not arg.startswith("-") and endpoint is None:
        endpoint = arg
        index += 1
    else:
        fail("Unexpected gh api argument")

if endpoint and "/releases/tags/" in endpoint:
    fail("HTTP 404: draft releases are not available by REST tag")
if endpoint != fixture["endpoint"]:
    fail("Unexpected release ID or repository")
if method == "GET":
    if fixture.get("get_error"):
        fail("HTTP 503: release lookup failed")
    print(json.dumps(fixture["release"]))
elif method == "PATCH":
    if payload != {"draft": False, "make_latest": "true", "tag_name": fixture["tag"]}:
        fail("Publishing must retain the tag and use the REST field types")
    print(json.dumps(fixture["published"]))
else:
    fail("Unexpected mutation")
'''


class ReleasePublishWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.dist = self.root / "dist"
        self.runner = self.root / "runner"
        self.bin = self.root / "bin"
        for directory in (self.dist, self.runner, self.bin):
            directory.mkdir()
        files = {
            "CCBar.dmg": b"disk image fixture",
            "CCBar.app.zip": b"archive fixture",
            "appcast.xml": b"<rss>signed feed fixture</rss>",
            "release-notes.md": "## 本版亮点\n\n- 更新内容\n".encode(),
            "version.json": b'{"version":"2.0.0"}\n',
        }
        for name, content in files.items():
            (self.dist / name).write_bytes(content)
        release = {
            "id": RELEASE_ID,
            "draft": True,
            "tag_name": TAG,
            "assets": [{"name": name, "state": "uploaded", "size": len(content)}
                       for name, content in files.items()],
        }
        self.fixture = {
            "id": RELEASE_ID,
            "tag": TAG,
            "repository": REPOSITORY,
            "endpoint": f"repos/{REPOSITORY}/releases/{RELEASE_ID}",
            "release": release,
            "published": {**copy.deepcopy(release), "draft": False},
        }
        fake_gh = self.bin / "gh"
        fake_gh.write_text(f"#!{sys.executable}\n" + textwrap.dedent(FAKE_GH))
        fake_gh.chmod(0o755)
        self.fixture_path = self.root / "release-fixture.json"
        self.calls_path = self.root / "gh-calls.jsonl"

    def run_publish(self):
        self.fixture_path.write_text(json.dumps(self.fixture))
        self.calls_path.write_text("")
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", publish_step_script()],
            cwd=self.root,
            env={**os.environ,
                 "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                 "RUNNER_TEMP": str(self.runner), "TAG": TAG, "GITHUB_REPOSITORY": REPOSITORY,
                 "CCBAR_TEST_RELEASE_FIXTURE": str(self.fixture_path),
                 "CCBAR_TEST_GH_CALLS": str(self.calls_path)},
            text=True, capture_output=True, timeout=10,
        )
        calls = [json.loads(line) for line in self.calls_path.read_text().splitlines()]
        patches = [args for args in calls if args[0] == "api" and "PATCH" in args]
        return result, calls, patches

    def test_draft_is_verified_and_published_using_the_same_numeric_id(self):
        result, calls, patches = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(patches), 1)
        self.assertIn(self.fixture["endpoint"], patches[0])
        self.assertFalse(any("/releases/tags/" in arg for args in calls for arg in args))
        published = json.loads((self.runner / "published-release.json").read_text())
        self.assertEqual(published["id"], RELEASE_ID)
        self.assertEqual(published["tag_name"], TAG)
        self.assertIs(published["draft"], False)

    def test_invalid_draft_or_upload_never_reaches_publish(self):
        cases = {
            "wrong release ID": lambda release: release.update(id=RELEASE_ID + 1),
            "wrong tag": lambda release: release.update(tag_name="v1.9.9"),
            "already published": lambda release: release.update(draft=False),
            "missing asset": lambda release: release["assets"].pop(),
            "duplicate asset": lambda release: release["assets"].__setitem__(-1, copy.deepcopy(release["assets"][0])),
            "wrong size": lambda release: release["assets"][0].update(size=999),
            "incomplete upload": lambda release: release["assets"][0].update(state="starter"),
        }
        valid = copy.deepcopy(self.fixture["release"])
        for name, mutate in cases.items():
            with self.subTest(name=name):
                self.fixture["release"] = copy.deepcopy(valid)
                mutate(self.fixture["release"])
                result, _, patches = self.run_publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(patches, [])

    def test_failed_release_lookup_never_reaches_publish(self):
        self.fixture["get_error"] = True
        result, _, patches = self.run_publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(patches, [])

    def test_publish_response_must_confirm_the_expected_release(self):
        for key, value in (("id", RELEASE_ID + 1), ("tag_name", "v1.9.9"), ("draft", True)):
            with self.subTest(key=key):
                self.fixture["published"] = {**copy.deepcopy(self.fixture["release"]), "draft": False, key: value}
                result, _, patches = self.run_publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(patches), 1)


if __name__ == "__main__":
    unittest.main()
