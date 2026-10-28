#!/usr/bin/env python3
"""Prepare the build inputs for com.parsecgaming.parsec.

Copies the manifest and its local files into OUT_DIR, pins the extra-data
source to the .deb Parsec is serving right now (sha256 + size), adds that
.deb's version as a <release> in the metainfo, and prints a fingerprint of
the result. The fingerprint changes only when something that ends up in the
flatpak changes, so CI can skip builds when nothing upstream moved.

Usage: prepare.py [--repo DIR] OUT_DIR
Also fingerprints the web page (ci/publish.sh + ci/site/) separately, so a
page change republishes the site without touching the app.
Outputs: OUT_DIR/inputs.json, and key=value lines on $GITHUB_OUTPUT if set.
"""

import argparse
import email.utils
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

import yaml

APP_ID = "com.parsecgaming.parsec"


def find_extra_data(manifest):
    for module in manifest["modules"]:
        if isinstance(module, dict) and module.get("name") == "parsec":
            for source in module["sources"]:
                if source.get("type") == "extra-data":
                    return source
    sys.exit("no extra-data source in the parsec module")


def download(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": "parsec-flatpak-autobuild"})
    with urllib.request.urlopen(req, timeout=60) as resp, open(dest, "wb") as f:
        shutil.copyfileobj(resp, f)
        return resp.headers.get("Last-Modified")


def deb_version(deb, workdir):
    """Read Version: from the .deb's control file (ar archive, any tar compression)."""
    members = subprocess.run(["ar", "t", deb], check=True, capture_output=True, text=True).stdout.split()
    control = next(m for m in members if m.startswith("control.tar"))
    tarball = Path(workdir) / control
    tarball.write_bytes(subprocess.run(["ar", "p", deb, control], check=True, capture_output=True).stdout)
    text = subprocess.run(["tar", "-xOf", tarball, "./control"], check=True, capture_output=True, text=True).stdout
    for line in text.splitlines():
        if line.startswith("Version:"):
            return line.split(":", 1)[1].strip()
    sys.exit("no Version: in the .deb control file")


def add_release(metainfo, version, date):
    text = metainfo.read_text()
    if f'version="{version}"' not in text:
        text = text.replace("<releases>", f'<releases>\n    <release version="{version}" date="{date}"/>', 1)
        metainfo.write_text(text)


def version_key(v):
    return [int(x) for x in str(v).split(".")]


def apply_overrides(manifest, path):
    overrides = yaml.safe_load(path.read_text()) if path.exists() else {}
    runtime = overrides.get("runtime-version")
    if runtime and version_key(runtime) > version_key(manifest["runtime-version"]):
        print(f"runtime-version {manifest['runtime-version']} -> {runtime} (ci/overrides.yml)", file=sys.stderr)
        manifest["runtime-version"] = str(runtime)


def bump_git_sources(manifest):
    """Move git sources to their newest tag, using each source's own
    x-checker-data tag-pattern (the rule Flathub's update bot follows), so
    new dependency releases land without waiting for the bot's PR."""
    bumps = {}
    for module in manifest["modules"]:
        for src in module.get("sources", []) if isinstance(module, dict) else []:
            checker = src.get("x-checker-data") or {}
            if src.get("type") != "git" or checker.get("type") != "git" or "tag-pattern" not in checker:
                continue
            pattern = re.compile(checker["tag-pattern"])
            out = subprocess.run(["git", "ls-remote", "--tags", src["url"]], check=True,
                                 capture_output=True, text=True).stdout
            commits = {}  # tag -> commit, preferring the peeled ^{} entry of annotated tags
            for line in out.splitlines():
                sha, ref = line.split("\t")
                tag = ref.removeprefix("refs/tags/")
                peeled = tag.endswith("^{}")
                tag = tag.removesuffix("^{}")
                if pattern.match(tag) and (peeled or tag not in commits):
                    commits[tag] = sha
            if not commits:
                continue
            key = lambda t: version_key(pattern.match(t).group(1))
            newest = max(commits, key=key)
            if key(newest) > key(src["tag"]):
                print(f"{module['name']}: {src['tag']} -> {newest} (newest tag)", file=sys.stderr)
                bumps[module["name"]] = newest
                src["tag"], src["commit"] = newest, commits[newest]
    return bumps


def fingerprint(root, paths):
    h = hashlib.sha256()
    for path in sorted(paths):
        h.update(str(path.relative_to(root)).encode() + b"\0")
        h.update(hashlib.sha256(path.read_bytes()).digest())
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".", type=Path)
    ap.add_argument("out_dir", type=Path)
    args = ap.parse_args()

    manifest_path = args.repo / f"{APP_ID}.yml"
    manifest = yaml.safe_load(manifest_path.read_text())
    apply_overrides(manifest, args.repo / "ci" / "overrides.yml")
    git_bumps = bump_git_sources(manifest)
    source = find_extra_data(manifest)

    with tempfile.TemporaryDirectory() as tmp:
        deb = Path(tmp) / source["filename"]
        last_modified = download(source["url"], deb)
        data = deb.read_bytes()
        sha256, size = hashlib.sha256(data).hexdigest(), len(data)
        version = deb_version(deb, tmp)
    date = (email.utils.parsedate_to_datetime(last_modified) if last_modified else None)
    date = date.strftime("%Y-%m-%d") if date else "1970-01-01"

    if args.out_dir.exists():
        shutil.rmtree(args.out_dir)
    args.out_dir.mkdir(parents=True)

    # Local files the manifest references, plus anything it needs at build time.
    for module in manifest["modules"]:
        for src in module.get("sources", []) if isinstance(module, dict) else []:
            if src.get("type") == "file" and "path" in src:
                shutil.copy2(args.repo / src["path"], args.out_dir / src["path"])

    upstream_sha = source["sha256"]
    source["sha256"], source["size"] = sha256, size
    (args.out_dir / f"{APP_ID}.yml").write_text(yaml.safe_dump(manifest, sort_keys=False))
    add_release(args.out_dir / f"{APP_ID}.metainfo.xml", version, date)

    info = {
        # What ends up in the flatpak; a change means a new build users update to.
        "fingerprint": fingerprint(args.out_dir, (p for p in args.out_dir.rglob("*")
                                                  if p.is_file() and p.name != "inputs.json")),
        # Only the web page around the repo; a change republishes the site, not the app.
        "site_fingerprint": fingerprint(args.repo, [args.repo / "ci/publish.sh",
                                                    *(args.repo / "ci/site").rglob("*")]),
        "version": version,
        "deb_date": date,
        "deb_sha256": sha256,
        "deb_size": size,
        "upstream_manifest_sha256_matches": upstream_sha == sha256,
        "runtime_version": str(manifest["runtime-version"]),
        "git_bumps": git_bumps,
    }
    (args.out_dir / "inputs.json").write_text(json.dumps(info, indent=2) + "\n")
    print(json.dumps(info, indent=2))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            for key, value in info.items():
                f.write(f"{key}={json.dumps(value) if isinstance(value, (bool, dict)) else value}\n")


if __name__ == "__main__":
    main()
