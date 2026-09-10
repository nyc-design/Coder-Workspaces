#!/usr/bin/env python3
"""Select a complete, published Blender ARM64 release, never GitHub's /latest."""
import argparse
import json
import os
import re
import urllib.request


def select_release(releases):
    candidates = []
    for release in releases:
        match = re.fullmatch(r"blender-(\d+\.\d+\.\d+)", release.get("tag_name", ""))
        if not match or release.get("draft") or release.get("prerelease"):
            continue
        if not release.get("published_at"):
            continue
        version = match.group(1)
        archive = f"blender-{version}-linux-arm64.tar.xz"
        assets = {a["name"]: a for a in release.get("assets", []) if a.get("state") == "uploaded" and a.get("size", 0) > 0}
        if archive not in assets or archive + ".sha256" not in assets:
            continue
        candidates.append((release, version, assets[archive], assets[archive + ".sha256"]))
    if not candidates:
        raise ValueError("No published blender-X.Y.Z release with complete ARM64 archive/checksum assets")
    release, version, archive, checksum = max(
        candidates, key=lambda item: (item[0]["published_at"], item[0].get("id", 0), item[1])
    )
    return {
        "version": version,
        "tag": release["tag_name"],
        "release_id": str(release["id"]),
        "arm64_url": archive["browser_download_url"],
        "arm64_sha256_url": checksum["browser_download_url"],
    }


def resolve(repository, version=None):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Expected repository in owner/name format")
    if version and not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Expected Blender version X.Y.Z")
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "modeling-dev-builder"}
    if os.environ.get("GH_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GH_TOKEN']}"
    releases = []
    page = 1
    while True:
        path = f"tags/blender-{version}" if version else f"?per_page=100&page={page}"
        url = f"https://api.github.com/repos/{repository}/releases/{path}" if version else f"https://api.github.com/repos/{repository}/releases{path}"
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
            data = json.load(response)
        if version:
            releases.append(data)
            break
        releases.extend(data)
        if len(data) < 100:
            break
        page += 1
    return select_release(releases)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="nyc-design/Coder-Workspaces")
    parser.add_argument("--version")
    parser.add_argument("--github-output")
    args = parser.parse_args()
    result = resolve(args.repository, args.version)
    print(json.dumps(result, sort_keys=True))
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as output:
            for key, value in result.items():
                output.write(f"{key}={value}\n")
