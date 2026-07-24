#!/usr/bin/env python3
"""Point the public download manifest and download page at a released version.

Called by script/package_release.sh only after a DMG has passed notarization,
stapling, signature validation, and Gatekeeper. Both files are replaced
atomically, and the manifest is rolled back if the page write fails, so the
updater can never advertise a version whose artifacts do not exist.

Usage: update_public_manifest.py VERSION VERSION_JSON INDEX_HTML
Optional RELEASE_NOTES environment variable overrides the manifest notes.

This lives in its own file rather than a here-document inside the shell script
so that CI can execute it against fixtures. As a here-document it was invisible
to `bash -n`, which let a NameError sit in the release path undetected.
"""

import json
import os
import re
import stat
import sys
import tempfile

RELEASE_NOTE_PATTERN = r'(class="release-note">Version )[0-9A-Za-z._-]+'
DOWNLOAD_URL_TEMPLATE = (
    "https://github.com/bhino50/finder-path/releases/download/"
    "v{version}/FinderPath-{version}.dmg"
)


def stage_file(path, prefix, write_content):
    """Write content to a sibling temp file that can replace `path` atomically."""
    directory = os.path.dirname(path) or "."
    mode = stat.S_IMODE(os.stat(path).st_mode)
    temporary_path = ""
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, prefix=prefix, delete=False
        ) as destination:
            temporary_path = destination.name
            write_content(destination)
        os.chmod(temporary_path, mode)
        return temporary_path
    except Exception:
        if temporary_path:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass
        raise


def update(version, manifest_path, index_path, notes=None):
    with open(manifest_path, encoding="utf-8") as source:
        original_manifest = source.read()
    manifest = json.loads(original_manifest)
    if not isinstance(manifest, dict):
        raise ValueError(f"{manifest_path} must contain a JSON object")

    manifest["version"] = version
    manifest["downloadURL"] = DOWNLOAD_URL_TEMPLATE.format(version=version)
    # An empty RELEASE_NOTES is treated as "not supplied" so an exported but
    # blank variable cannot publish a manifest with no release notes.
    manifest["notes"] = notes if notes else f"FinderPath {version}."

    with open(index_path, encoding="utf-8") as source:
        original_index = source.read()
    index, replacements = re.subn(
        RELEASE_NOTE_PATTERN,
        rf"\g<1>{version}",
        original_index,
        count=1,
    )
    if replacements != 1:
        raise ValueError(f"Could not update the release version label in {index_path}")

    def write_manifest(destination):
        json.dump(manifest, destination, indent=2)
        destination.write("\n")

    manifest_staged = stage_file(manifest_path, ".version.", write_manifest)
    index_staged = ""
    manifest_rollback = ""
    manifest_replaced = False
    try:
        index_staged = stage_file(
            index_path, ".index.", lambda destination: destination.write(index)
        )
        manifest_rollback = stage_file(
            manifest_path,
            ".rollback.",
            lambda destination: destination.write(original_manifest),
        )
        os.replace(manifest_staged, manifest_path)
        manifest_staged = ""
        manifest_replaced = True
        os.replace(index_staged, index_path)
        index_staged = ""
    except Exception:
        # If the second commit fails, restore the exact original manifest before
        # reporting failure so the updater can never point at artifacts cleanup
        # is about to remove.
        if manifest_replaced:
            os.replace(manifest_rollback, manifest_path)
            manifest_rollback = ""
        raise
    finally:
        for temporary_path in (manifest_staged, index_staged, manifest_rollback):
            if temporary_path:
                try:
                    os.unlink(temporary_path)
                except OSError:
                    pass


def main(argv):
    if len(argv) != 4:
        print(
            "usage: update_public_manifest.py VERSION VERSION_JSON INDEX_HTML",
            file=sys.stderr,
        )
        return 2
    update(argv[1], argv[2], argv[3], os.environ.get("RELEASE_NOTES"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
