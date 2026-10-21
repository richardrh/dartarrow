"""Validate an existing release tag and update only a GitHub draft release."""

import argparse
import json
from pathlib import Path
import re
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def draft_for(tag):
    releases = json.loads(run("gh", "api", "--paginate", "--slurp", "repos/{owner}/{repo}/releases"))
    matches = [release for page in releases for release in page if release["tag_name"] == tag]
    if len(matches) > 1:
        raise SystemExit("Multiple releases unexpectedly use this tag")
    release = matches[0] if matches else None
    if release is not None and not release["draft"]:
        raise SystemExit("Refusing to modify an already published release")
    return release


def validate(tag):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise SystemExit("Tag must be exactly v<stable pubspec version>")
    if run("git", "cat-file", "-t", f"refs/tags/{tag}") != "tag":
        raise SystemExit("Release requires an existing annotated tag")
    commit = run("git", "rev-parse", f"refs/tags/{tag}^{{commit}}")
    if commit != run("git", "rev-parse", "refs/remotes/origin/main"):
        raise SystemExit("Tag must point to the current verified main commit")
    manifest = run("git", "show", f"{commit}:pubspec.yaml")
    version = re.search(r"^version:\s*(\S+)\s*$", manifest, re.MULTILINE)
    if version is None or tag != "v" + version.group(1):
        raise SystemExit("Tag does not match pubspec.yaml version")
    runs = json.loads(run("gh", "run", "list", "--workflow", "ci.yml", "--branch", "main", "--event", "push", "--commit", commit, "--status", "success", "--json", "headSha,conclusion"))
    if not any(item["headSha"] == commit and item["conclusion"] == "success" for item in runs):
        raise SystemExit("The exact main commit has no successful push CI run")
    draft_for(tag)
    print(f"Validated {tag} at {commit} with successful main CI")


def update_draft(tag, directory):
    validate(tag)
    root = Path(directory)
    expected = [root / f"dartaframes_arrow-{tag}-source.tar.gz", root / "SHA256SUMS"]
    if not all(path.is_file() for path in expected):
        raise SystemExit("Expected source archive and SHA256SUMS are required")
    release = draft_for(tag)
    notes = (f"Verified source distribution for dartaframes_arrow {tag[1:]}. "
             "Contains no native runtime dependency. This draft does not publish to pub.dev. "
             "Review the source archive and SHA256SUMS before manually publishing this GitHub release.")
    if release is None:
        subprocess.run(["gh", "release", "create", tag, "--verify-tag", "--draft", "--title", tag, "--notes", notes, *map(str, expected)], check=True)
    else:
        # Never delete unknown assets or touch a published release on a rerun.
        subprocess.run(["gh", "release", "upload", tag, *map(str, expected), "--clobber"], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "draft"])
    parser.add_argument("tag")
    parser.add_argument("--directory", default="release-assets")
    args = parser.parse_args()
    if args.command == "validate":
        validate(args.tag)
    else:
        update_draft(args.tag, args.directory)


if __name__ == "__main__":
    main()
