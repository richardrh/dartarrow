"""Validate a pushed release tag, report its pub.dev state, and publish the GitHub release."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request

PACKAGE = "dartarrow"


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def version_of(tag):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise SystemExit("Tag must be exactly v<stable pubspec version>")
    return tag[1:]


def changelog_section(version, changelog):
    """Return the body of the `## <version>` section of CHANGELOG.md."""
    match = re.search(
        rf"^## {re.escape(version)}[ \t]*\n(.*?)(?=^## |\Z)", changelog, re.MULTILINE | re.DOTALL
    )
    if match is None or not match.group(1).strip():
        raise SystemExit(f"CHANGELOG.md has no '## {version}' section")
    return match.group(1).strip() + "\n"


def release_for(tag):
    releases = json.loads(run("gh", "api", "--paginate", "--slurp", "repos/{owner}/{repo}/releases"))
    matches = [release for page in releases for release in page if release["tag_name"] == tag]
    if len(matches) > 1:
        raise SystemExit("Multiple releases unexpectedly use this tag")
    return matches[0] if matches else None


def validate(tag):
    version = version_of(tag)
    if run("git", "cat-file", "-t", f"refs/tags/{tag}") != "tag":
        raise SystemExit("Release requires an annotated tag")
    commit = run("git", "rev-parse", f"refs/tags/{tag}^{{commit}}")
    on_main = subprocess.run(["git", "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main"])
    if on_main.returncode != 0:
        raise SystemExit("Tag must point to a commit on main")
    manifest = run("git", "show", f"{commit}:pubspec.yaml")
    declared = re.search(r"^version:\s*(\S+)\s*$", manifest, re.MULTILINE)
    if declared is None or declared.group(1) != version:
        raise SystemExit("Tag does not match pubspec.yaml version")
    changelog_section(version, run("git", "show", f"{commit}:CHANGELOG.md"))
    runs = json.loads(run("gh", "run", "list", "--workflow", "ci.yml", "--branch", "main", "--event", "push", "--commit", commit, "--status", "success", "--json", "headSha,conclusion"))
    if not any(item["headSha"] == commit and item["conclusion"] == "success" for item in runs):
        raise SystemExit("The tagged main commit has no successful push CI run")
    print(f"Validated {tag} at {commit} with successful main CI")


def pub_dev_state(tag):
    """Print `published=true|false` (GITHUB_OUTPUT syntax) for the tagged version."""
    url = f"https://pub.dev/api/packages/{PACKAGE}/versions/{version_of(tag)}"
    try:
        with urllib.request.urlopen(url, timeout=30):
            published = True
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        published = False
    print(f"published={'true' if published else 'false'}")


def write_notes(tag, output):
    version = version_of(tag)
    body = changelog_section(version, Path("CHANGELOG.md").read_text(encoding="utf-8"))
    footer = (
        f"\npub.dev: https://pub.dev/packages/{PACKAGE}/versions/{version}\n\n"
        "The attached source archive is the exact tagged tree that passed the release checks; "
        "verify it with `SHA256SUMS`.\n"
    )
    Path(output).write_text(body + footer, encoding="utf-8")


def publish(tag, directory, notes):
    root = Path(directory)
    assets = [root / f"{PACKAGE}-{tag}-source.tar.gz", root / "SHA256SUMS"]
    if not all(path.is_file() for path in assets) or not Path(notes).is_file():
        raise SystemExit("Expected source archive, SHA256SUMS and release notes are required")
    release = release_for(tag)
    if release is None:
        subprocess.run(["gh", "release", "create", tag, "--verify-tag", "--title", tag, "--notes-file", notes, *map(str, assets)], check=True)
    elif release["draft"]:
        subprocess.run(["gh", "release", "upload", tag, *map(str, assets), "--clobber"], check=True)
        subprocess.run(["gh", "release", "edit", tag, "--draft=false", "--title", tag, "--notes-file", notes], check=True)
    else:
        # Published releases are immutable here: a rerun must not rewrite them.
        print(f"GitHub release {tag} is already published; leaving it unchanged")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "pub-dev-state", "notes", "publish"])
    parser.add_argument("tag")
    parser.add_argument("--directory", default="release-assets")
    parser.add_argument("--notes", default="release-notes.md")
    args = parser.parse_args()
    if args.command == "validate":
        validate(args.tag)
    elif args.command == "pub-dev-state":
        pub_dev_state(args.tag)
    elif args.command == "notes":
        write_notes(args.tag, args.notes)
    else:
        publish(args.tag, args.directory, args.notes)


if __name__ == "__main__":
    main()
