#!/usr/bin/env python3
"""Resolve the git submodules of an ArmorPaint source checkout.

The upstream repositories pin their dependencies as git submodules. Several of
those pins use GitHub URLs that no longer resolve (for example
armory3d/Kinc and armory3d/haxe_bin), so a plain `git submodule update` fails
and leaves empty directories behind.

This script reads the pinned commit of every submodule straight from the git
tree, fetches that exact commit (trying the recorded URL first and then the
Kode mirror of the same repository name) and records everything in a JSON lock
file. Git commits are content addressed, so a commit fetched from a mirror is
byte-identical to the original as long as the SHA matches, which is verified.

Two kinds of submodule are handled differently:

* source submodules (armorcore, Kinc) are copied into the source tree without
  their .git directory so they can be committed to the workspace repository;
* toolchain/binary submodules (v8, haxe, onnx, Kinc/Tools/*) are large,
  platform specific binary packages. They are NOT copied. They are recorded in
  the lock file and fetched at compile time from the same pinned commits.

Usage:
    armorpaint_fetch_submodules.py --source DIR --lock FILE
        --tag TAG --commit SHA
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

# Submodules (path relative to the source root) whose content is source code
# and is committed together with the rest of the tree.
SOURCE_SUBMODULES = {"armorcore", "armorcore/Kinc"}

# Mirror owner tried after the URL recorded in .gitmodules.
MIRROR_OWNER = "Kode"


def log(message=""):
    print(message, flush=True)


def git(args, cwd=None, check=True, capture=True):
    result = subprocess.run(
        ["git", "-c", "core.autocrlf=false", "-c", "core.safecrlf=false"] + args,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        env=dict(os.environ, GIT_TERMINAL_PROMPT="0"),
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            "git %s failed (exit %d):\n%s"
            % (" ".join(args), result.returncode, result.stdout or "")
        )
    return result


def gitlinks(repo):
    """Return {path: sha} for every gitlink (mode 160000) in HEAD."""
    out = git(["ls-tree", "-r", "HEAD"], cwd=repo).stdout
    links = {}
    for line in out.splitlines():
        match = re.match(r"^160000 commit ([0-9a-f]{40})\t(.+)$", line)
        if match:
            links[match.group(2)] = match.group(1)
    return links


def submodule_urls(repo):
    """Return {path: url} parsed from the .gitmodules file of a checkout."""
    gitmodules = os.path.join(repo, ".gitmodules")
    if not os.path.isfile(gitmodules):
        return {}
    out = git(
        ["config", "-f", gitmodules, "--get-regexp", r"^submodule\..*\.(path|url)$"],
        cwd=repo,
        check=False,
    ).stdout
    names = {}
    for line in out.splitlines():
        key, _, value = line.partition(" ")
        match = re.match(r"^submodule\.(.+)\.(path|url)$", key)
        if match:
            names.setdefault(match.group(1), {})[match.group(2)] = value.strip()
    return {v["path"]: v["url"] for v in names.values() if "path" in v and "url" in v}


def candidate_urls(url):
    """The recorded URL followed by the Kode mirror of the same repository."""
    candidates = [url]
    match = re.match(r"^(https://github\.com/)([^/]+)/(.+?)(\.git)?$", url)
    if match and match.group(2).lower() != MIRROR_OWNER.lower():
        candidates.append(
            "%s%s/%s" % (match.group(1), MIRROR_OWNER, match.group(3))
        )
    return candidates


def fetch_commit(urls, sha, dest):
    """Fetch exactly `sha` into `dest`. Returns the URL that worked."""
    errors = []
    for url in urls:
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        os.makedirs(dest)
        try:
            git(["init", "-q"], cwd=dest)
            git(["remote", "add", "origin", url], cwd=dest)
            git(["fetch", "-q", "--depth", "1", "origin", sha], cwd=dest)
            git(["checkout", "-q", "--detach", "FETCH_HEAD"], cwd=dest)
            head = git(["rev-parse", "HEAD"], cwd=dest).stdout.strip()
            if head != sha:
                raise RuntimeError("fetched %s but expected %s" % (head, sha))
            return url
        except RuntimeError as error:
            errors.append("%s -> %s" % (url, str(error).strip().splitlines()[-1]))
            log("    not available from %s" % url)
    raise RuntimeError(
        "Commit %s could not be fetched from any candidate URL:\n  %s"
        % (sha, "\n  ".join(errors))
    )


def process(repo, prefix, records, depth=0):
    """Handle every gitlink of `repo`; `prefix` is the path of repo in the root."""
    urls = submodule_urls(repo)
    for path, sha in sorted(gitlinks(repo).items()):
        rel = (prefix + "/" + path) if prefix else path
        url = urls.get(path)
        if not url:
            raise RuntimeError(
                "Submodule %s has no URL in %s/.gitmodules" % (rel, repo)
            )
        candidates = candidate_urls(url)
        materialize = rel in SOURCE_SUBMODULES
        record = {
            "path": rel,
            "sha": sha,
            "urls": candidates,
            "role": "source" if materialize else "toolchain",
            "materialized": materialize,
        }
        indent = "  " * depth
        if materialize:
            log("%s- %s @ %s (source, copied into the tree)" % (indent, rel, sha[:12]))
            dest = os.path.join(repo, path)
            if os.path.isdir(dest):
                shutil.rmtree(dest)
            record["fetched_from"] = fetch_commit(candidates, sha, dest)
            records.append(record)
            process(dest, rel, records, depth + 1)
            shutil.rmtree(os.path.join(dest, ".git"), ignore_errors=True)
        else:
            log("%s- %s @ %s (toolchain, recorded for compile time)" % (indent, rel, sha[:12]))
            # Prove now that the pinned commit is reachable from a candidate,
            # so a missing dependency is reported by the clone and not the build.
            record["fetched_from"] = first_reachable(candidates, sha)
            records.append(record)


def first_reachable(urls, sha):
    """Return the first URL from which `sha` can be fetched (metadata only)."""
    scratch = os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "ap-probe")
    errors = []
    for url in urls:
        shutil.rmtree(scratch, ignore_errors=True)
        os.makedirs(scratch)
        try:
            git(["init", "-q"], cwd=scratch)
            git(["remote", "add", "origin", url], cwd=scratch)
            # --filter=blob:none transfers commits and trees only, so large
            # binary submodules are verified without downloading their content.
            git(["fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", sha], cwd=scratch)
            shutil.rmtree(scratch, ignore_errors=True)
            return url
        except RuntimeError as error:
            errors.append("%s -> %s" % (url, str(error).strip().splitlines()[-1]))
            log("    not available from %s" % url)
    shutil.rmtree(scratch, ignore_errors=True)
    raise RuntimeError(
        "Pinned commit %s is not reachable from any candidate URL:\n  %s"
        % (sha, "\n  ".join(errors))
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--source", required=True, help="cloned source checkout (with .git)")
    parser.add_argument("--lock", required=True, help="JSON lock file to write")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()

    source = os.path.abspath(args.source)
    if not os.path.isdir(os.path.join(source, ".git")):
        raise SystemExit("--source must be a git checkout: %s" % source)

    head = git(["rev-parse", "HEAD"], cwd=source).stdout.strip()
    if head != args.commit:
        raise SystemExit("Checkout is at %s but %s was expected." % (head, args.commit))

    log("Resolving submodules of %s (%s)" % (args.tag, head[:12]))
    records = []
    process(source, "", records)

    lock = {
        "schema": 1,
        "source_tag": args.tag,
        "source_commit": head,
        "submodules": records,
    }
    with open(args.lock, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(lock, handle, indent=2)
        handle.write("\n")

    log("")
    log("Submodules recorded: %d (%d copied as source)" % (
        len(records), sum(1 for r in records if r["materialized"])))
    log("Lock file: %s" % args.lock)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        sys.stderr.write("ERROR: %s\n" % error)
        sys.exit(1)
