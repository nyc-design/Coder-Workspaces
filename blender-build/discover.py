#!/usr/bin/env python3
"""Select a published stable Blender release and pin its Git commit."""

import argparse
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from html.parser import HTMLParser

DOWNLOAD_ROOT = "https://download.blender.org/release/"
SOURCE_REPOSITORY = "https://github.com/blender/blender.git"


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.links.extend(value for key, value in attrs if key == "href" and value)


def links(text):
    parser = Links()
    parser.feed(text)
    return parser.links


def version_key(version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError(f"Not a stable release version: {version!r}")
    return tuple(map(int, version.split(".")))


def fetch(url, token=None):
    headers = {"User-Agent": "Coder-Workspaces-Blender-ARM64-build"}
    if token:
        headers.update(Authorization=f"Bearer {token}", Accept="application/vnd.github+json")
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        return response.read().decode("utf-8")


def published_versions(series):
    versions = []
    for link in links(fetch(f"{DOWNLOAD_ROOT}Blender{series}/")):
        match = re.fullmatch(r"blender-([0-9]+\.[0-9]+\.[0-9]+)\.sha256", link)
        if match and match[1].startswith(series + "."):
            versions.append(match[1])
    return versions


def select_version(requested):
    if requested:
        version_key(requested)
        if requested not in published_versions(".".join(requested.split(".")[:2])):
            raise ValueError(f"Blender {requested} is not a published stable release")
        return requested
    series = []
    for link in links(fetch(DOWNLOAD_ROOT)):
        match = re.fullmatch(r"Blender([0-9]+\.[0-9]+)/", link)
        if match:
            series.append(match[1])
    for item in sorted(set(series), key=lambda value: tuple(map(int, value.split("."))), reverse=True):
        versions = published_versions(item)
        if versions:
            return max(versions, key=version_key)
    raise RuntimeError("No published stable Blender release found")


def source_commit(version):
    tag = f"refs/tags/v{version}"
    result = subprocess.run(
        ["git", "ls-remote", "--tags", SOURCE_REPOSITORY, tag, tag + "^{}"],
        check=True, capture_output=True, text=True, timeout=120,
    )
    refs = dict((ref, sha) for sha, ref in (line.split() for line in result.stdout.splitlines()))
    sha = refs.get(tag + "^{}", refs.get(tag, ""))
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise RuntimeError(f"Unable to resolve upstream v{version} to a commit")
    return sha


def release_state(repository, tag, token):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GitHub repository")
    try:
        release = json.loads(fetch(
            f"https://api.github.com/repos/{repository}/releases/tags/{tag}", token,
        ))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return "missing"
        raise
    # Never overwrite a public release. A draft left by an interrupted upload can resume.
    return "draft" if release["draft"] else "published"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="", help="Optional exact published version, e.g. 5.2.1")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"), required=False)
    parser.add_argument("--output", default=os.environ.get("GITHUB_OUTPUT"))
    args = parser.parse_args()
    if not args.repository:
        parser.error("--repository or GITHUB_REPOSITORY is required")
    version = select_version(args.version)
    tag = f"blender-{version}"
    state = release_state(args.repository, tag, os.environ.get("GH_TOKEN"))
    result = {
        "version": version,
        "tag": tag,
        "source_sha": source_commit(version),
        "build": "false" if state == "published" else "true",
        "release_state": state,
    }
    print(json.dumps(result, indent=2))
    if args.output:
        with open(args.output, "a", encoding="utf-8") as output:
            for key, value in result.items():
                output.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
