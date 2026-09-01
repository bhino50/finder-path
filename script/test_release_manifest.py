#!/usr/bin/env python3
"""Regression tests for script/update_public_manifest.py.

The public release path runs this updater only after several minutes of Apple
notarization round-trips, and package_release.sh deletes the notarized DMG and
ZIP if it fails. A silent error here therefore costs a whole release, so the
updater gets executed against fixtures on every CI run.

Usage: test_release_manifest.py
"""

import json
import os
import shutil
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

import update_public_manifest  # noqa: E402


FAILURES = []


def check(condition, message):
    if not condition:
        FAILURES.append(message)


def fixture_paths(work_dir):
    """Copy the real download-site files so tests exercise the shipping shapes."""
    manifest = os.path.join(work_dir, "version.json")
    index = os.path.join(work_dir, "index.html")
    shutil.copyfile(os.path.join(ROOT_DIR, "download-site", "version.json"), manifest)
    shutil.copyfile(os.path.join(ROOT_DIR, "download-site", "index.html"), index)
    return manifest, index


def test_updates_both_files():
    with tempfile.TemporaryDirectory() as work_dir:
        manifest_path, index_path = fixture_paths(work_dir)
        with open(manifest_path, encoding="utf-8") as source:
            previous_version = json.load(source)["version"]
        with open(index_path, encoding="utf-8") as source:
            check(
                f'class="release-note">Version {previous_version}' in source.read(),
                "fixture download page should start on the shipping version",
            )
        update_public_manifest.update("9.9", manifest_path, index_path)

        with open(manifest_path, encoding="utf-8") as source:
            manifest = json.load(source)
        check(manifest["version"] == "9.9", "manifest version should be updated")
        check(
            manifest["downloadURL"]
            == "https://github.com/bhino50/finder-path/releases/download/"
            "v9.9/FinderPath-9.9.dmg",
            "manifest downloadURL should point at the new tag and asset",
        )
        check(
            manifest["notes"] == "FinderPath 9.9.",
            "manifest notes should default to the version",
        )

        with open(index_path, encoding="utf-8") as source:
            index = source.read()
        check(
            'class="release-note">Version 9.9' in index,
            "download page should show the new version",
        )
        check(
            f'class="release-note">Version {previous_version}' not in index,
            "download page should not keep the previous version label",
        )


def test_release_notes_override():
    with tempfile.TemporaryDirectory() as work_dir:
        manifest_path, index_path = fixture_paths(work_dir)
        update_public_manifest.update("9.9", manifest_path, index_path, notes="Hello.")
        with open(manifest_path, encoding="utf-8") as source:
            check(
                json.load(source)["notes"] == "Hello.",
                "explicit release notes should win",
            )


def test_blank_release_notes_falls_back():
    with tempfile.TemporaryDirectory() as work_dir:
        manifest_path, index_path = fixture_paths(work_dir)
        update_public_manifest.update("9.9", manifest_path, index_path, notes="")
        with open(manifest_path, encoding="utf-8") as source:
            check(
                json.load(source)["notes"] == "FinderPath 9.9.",
                "an exported-but-empty RELEASE_NOTES should not blank the notes",
            )


def test_missing_version_label_leaves_manifest_untouched():
    """The manifest must never advertise a version the page rollout failed on."""
    with tempfile.TemporaryDirectory() as work_dir:
        manifest_path, index_path = fixture_paths(work_dir)
        with open(index_path, "w", encoding="utf-8") as destination:
            destination.write("<html>no version label here</html>")
        with open(manifest_path, encoding="utf-8") as source:
            before = source.read()

        raised = False
        try:
            update_public_manifest.update("9.9", manifest_path, index_path)
        except ValueError:
            raised = True
        check(raised, "a missing version label should raise")

        with open(manifest_path, encoding="utf-8") as source:
            check(
                source.read() == before,
                "manifest must be unchanged when the page cannot be updated",
            )


def test_rejects_non_object_manifest():
    with tempfile.TemporaryDirectory() as work_dir:
        manifest_path, index_path = fixture_paths(work_dir)
        with open(manifest_path, "w", encoding="utf-8") as destination:
            destination.write("[1, 2, 3]")
        raised = False
        try:
            update_public_manifest.update("9.9", manifest_path, index_path)
        except ValueError:
            raised = True
        check(raised, "a JSON array manifest should be rejected")


def test_leaves_no_temporary_files():
    with tempfile.TemporaryDirectory() as work_dir:
        manifest_path, index_path = fixture_paths(work_dir)
        update_public_manifest.update("9.9", manifest_path, index_path)
        leftovers = [
            name
            for name in os.listdir(work_dir)
            if name.startswith((".version.", ".index.", ".rollback."))
        ]
        check(not leftovers, f"staging files should be cleaned up, found {leftovers}")


def main():
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
    if FAILURES:
        for failure in FAILURES:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print(f"release manifest tests passed ({len(tests)} cases).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
