#!/usr/bin/env python3
"""Audit publishable files without reading the Keychain, the network or the AC.

Flags local paths, private IPs, MAC addresses, per-device AES keys
(thing_secret_key values), JWT tokens and e-mail addresses, plus every term
listed in .local/deny.txt (one per line, # for comments). Use --deny TEXT to
add terms on the command line and --root DIR to audit a clean export. This is
a release check, not a guarantee that arbitrary files contain no sensitive data.
"""
import argparse
import ipaddress
from pathlib import Path
import re
import subprocess
import sys

PUBLIC_ROOTS = ("Sources", "Tests", "scripts")
PRIVATE_ROOTS = {".git", ".build", ".swiftpm", ".local", "dist", "research", "node_modules", "__pycache__"}
DENY_FILE = Path(".local") / "deny.txt"
IPV4 = re.compile(rb"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
MAC = re.compile(rb"(?<![a-zA-Z0-9])(?:[0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}(?![a-zA-Z0-9])")
HOME_PATH = re.compile(rb"/(?:Users|home)/[^/\s\"']+|/var/folders/[a-zA-Z0-9_/]+")
# Only a key with a value counts; the bare field name appears in code and docs.
THING_SECRET = re.compile(rb"""thing_secret_key["']?\s*[:=]\s*["'][^"'\s<>{}]{8,}["']""", re.IGNORECASE)
JWT = re.compile(rb"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")
EMAIL = re.compile(rb"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(?![A-Za-z0-9-])")
# Reserved documentation domains (RFC 2606) are safe in examples.
EXAMPLE_EMAIL_DOMAINS = (b"example.com", b"example.org", b"example.net")
# Documentation-only address blocks; loopback and multicast are protocol values.
EXAMPLE_NETWORKS = tuple(ipaddress.ip_network(block) for block in (
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "127.0.0.0/8", "224.0.0.0/4",
))
EXAMPLE_MACS = {b"00:00:00:00:00:00", b"00:11:22:33:44:55", b"ff:ff:ff:ff:ff:ff"}


def files_to_check(root):
    """Prefer Git's complete publication view, including newly added files."""
    git = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    if git.returncode == 0:
        return sorted({root / name.decode() for name in git.stdout.split(b"\0") if name})
    # A source export needs no repository initialization to be checked.
    candidates = []
    for file in root.rglob("*"):
        relative = file.relative_to(root)
        if any(part in PRIVATE_ROOTS for part in relative.parts):
            continue
        if file.is_file() and (len(relative.parts) == 1 or relative.parts[0] in PUBLIC_ROOTS):
            candidates.append(file)
    return sorted(candidates)


def denied_terms(path):
    """Read the private deny list. Its values are never printed."""
    if not path.is_file():
        return None
    terms = []
    for line in path.read_text(encoding="utf-8").splitlines():
        term = line.strip()
        if term and not term.startswith("#"):
            terms.append(term)
    return terms


def findings(data, denied):
    found = []
    for match in HOME_PATH.finditer(data):
        found.append((match.start(), "local user or temporary path"))
    for match in THING_SECRET.finditer(data):
        found.append((match.start(), "per-device thing_secret_key value"))
    for match in JWT.finditer(data):
        found.append((match.start(), "JWT token"))
    for match in EMAIL.finditer(data):
        domain = match.group().rsplit(b"@", 1)[1].lower()
        if not any(domain == d or domain.endswith(b"." + d) for d in EXAMPLE_EMAIL_DOMAINS):
            found.append((match.start(), "e-mail address"))
    for match in IPV4.finditer(data):
        try:
            address = ipaddress.ip_address(match.group().decode())
        except ValueError:
            continue
        if address in (ipaddress.ip_address("0.0.0.0"), ipaddress.ip_address("255.255.255.255")):
            continue
        if any(address in network for network in EXAMPLE_NETWORKS):
            continue
        if address.is_private or address.is_link_local:
            found.append((match.start(), "private network address"))
    for match in MAC.finditer(data):
        if match.group().lower().replace(b"-", b":") not in EXAMPLE_MACS:
            found.append((match.start(), "device MAC address"))
    lower = data.lower()
    for identifier in denied:
        encoded = identifier.encode().lower()
        start = lower.find(encoded) if encoded else -1
        while start != -1:
            found.append((start, "term from the deny list"))
            start = lower.find(encoded, start + 1)
    return sorted(set(found))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--deny", action="append", default=[], metavar="TEXT")
    parser.add_argument("--deny-file", type=Path, default=None, metavar="FILE",
                        help="deny list to read (default: ROOT/.local/deny.txt)")
    args = parser.parse_args()
    root = args.root.resolve()
    if not root.is_dir():
        parser.error("--root must be a directory")
    deny_path = args.deny_file or root / DENY_FILE
    from_file = denied_terms(deny_path)
    if from_file is None:
        print(f"Note: no deny list at {DENY_FILE.as_posix()}; only built-in checks ran.")
        from_file = []
    denied = from_file + args.deny
    checked = 0
    issues = []
    for file in files_to_check(root):
        relative = file.relative_to(root).as_posix()
        if file.is_symlink():
            issues.append(f"{relative}: symlink must be reviewed before publishing")
            continue
        if not file.is_file():
            continue
        data = file.read_bytes()
        checked += 1
        for offset, reason in findings(data, denied):
            line = data[:offset].count(b"\n") + 1
            # Never echo the sensitive value itself.
            issues.append(f"{relative}:{line}: {reason}")
    if issues:
        print("Privacy check found items to review:")
        print("\n".join(issues))
        return 1
    print(f"Privacy check passed: {checked} public files inspected, {len(denied)} denied terms.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
