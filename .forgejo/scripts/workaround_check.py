#!/usr/bin/env python3
"""Open a Forgejo issue when an upstream fix for a local workaround lands.

Finds comment lines in tracked files that say "remove once" or "drop once"
followed by a GitHub issue or pull request URL, for example:

    # Holds npm at 11; remove once https://github.com/npm/cli/issues/9800 is fixed

For every referenced upstream issue or PR that is now closed, opens one
Forgejo issue listing each place that references it. An existing issue with
the same title, open or closed, suppresses a new one.

Environment (set by Forgejo Actions): GITHUB_SERVER_URL, GITHUB_REPOSITORY,
FORGEJO_TOKEN. DRY_RUN=1 prints what would be opened without calling Forgejo.
"""
import json, os, re, subprocess, sys, urllib.error, urllib.parse, urllib.request
from collections import defaultdict

MARKER = re.compile(
    r"\b(?:remove|drop)\b.*?\bonce\b.*?"
    r"https://github\.com/([\w.-]+)/([\w.-]+)/(?:issues|pull)/(\d+)",
    re.IGNORECASE,
)
SELF = {".forgejo/scripts/workaround_check.py"}


def http_json(url, token=None, data=None):
    headers = {"Accept": "application/json", "User-Agent": "workaround-check"}
    if token:
        headers["Authorization"] = f"token {token}"
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def find_markers():
    out = subprocess.run(
        ["git", "grep", "-nIiE", r"(remove|drop).*once.*https://github\.com/"],
        capture_output=True, text=True,
    )
    if out.returncode not in (0, 1):
        sys.exit(f"git grep failed: {out.stderr.strip()}")
    refs = defaultdict(list)
    for line in out.stdout.splitlines():
        path, lineno, text = line.split(":", 2)
        if path in SELF:
            continue
        m = MARKER.search(text)
        if m:
            owner, repo, num = m.groups()
            refs[(owner, repo, int(num))].append((path, int(lineno), text.strip()))
    return refs


def main():
    server = os.environ.get("GITHUB_SERVER_URL", "").rstrip("/")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("FORGEJO_TOKEN", "")
    dry_run = os.environ.get("DRY_RUN") == "1"
    if not dry_run and not (server and repository and token):
        sys.exit("GITHUB_SERVER_URL, GITHUB_REPOSITORY and FORGEJO_TOKEN are required")

    refs = find_markers()
    print(f"Found {len(refs)} upstream reference(s) in workaround comments")
    failures = 0
    for (owner, repo, num), sites in sorted(refs.items()):
        ref = f"{owner}/{repo}#{num}"
        try:
            upstream = http_json(f"https://api.github.com/repos/{owner}/{repo}/issues/{num}")
        except (urllib.error.URLError, ValueError) as exc:
            print(f"::warning::{ref}: could not read upstream state: {exc}")
            failures += 1
            continue
        state = upstream.get("state")
        merged = (upstream.get("pull_request") or {}).get("merged_at")
        print(f"{ref}: {state}{' (merged)' if merged else ''}")
        if state != "closed":
            continue

        title = f"Workaround ready to review: {ref} closed"
        lines = [
            f"Upstream [{ref}]({upstream['html_url']}) (\"{upstream.get('title', '')}\") is closed.",
            "",
            "A closed issue means the fix is merged, not necessarily released. "
            "Check that a release contains it, then remove the workaround:",
            "",
        ]
        for path, lineno, text in sites:
            link = f"{server}/{repository}/src/branch/main/{path}#L{lineno}" if server else path
            lines.append(f"- [`{path}:{lineno}`]({link}): `{text}`")
        body = "\n".join(lines)

        if dry_run:
            print(f"Would open: {title}\n{body}\n")
            continue
        api = f"{server}/api/v1/repos/{repository}"
        try:
            query = urllib.parse.urlencode({"state": "all", "type": "issues", "q": ref, "limit": 50})
            existing = http_json(f"{api}/issues?{query}", token)
            if any(i.get("title") == title for i in existing):
                print(f"{ref}: issue already exists, skipping")
                continue
            created = http_json(f"{api}/issues", token, {"title": title, "body": body})
            print(f"{ref}: opened {created.get('html_url')}")
        except (urllib.error.URLError, ValueError) as exc:
            print(f"::error::{ref}: could not create Forgejo issue: {exc}")
            failures += 1

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
