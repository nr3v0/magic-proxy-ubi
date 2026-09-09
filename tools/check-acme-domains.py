#!/usr/bin/env python3
"""Cross-check an ACME domains file against a TLS-terminating frontend's ACLs.

This repo's ACME agent (ubi10/scripts/acme-agent.sh) issues certs for exactly
the domains listed in ACME_DOMAINS_FILE / ACME_DOMAINS -- a plain, human-
maintained list, with zero awareness of haproxy.cfg/conf.d. That's
intentional (see CLAUDE.md): the Host-header ACLs in a TLS-terminating
frontend are mostly loose prefix/substring fragments (`-m beg`, `-m sub`),
not literal domain names, so there's no reliable way to *derive* the domains
list from them automatically.

What this script does instead: flag drift between the two, so a human can
fix it.
  - A domain in the file that no ACL in the frontend matches -- possibly a
    stale cert nobody routes to anymore.
  - An ACL in the frontend (i.e. a route real traffic can hit) that no
    domain in the file matches -- traffic to it gets the self-signed
    bootstrap cert instead of a real one.

Only point this at a TLS-*terminating* frontend (one with `bind ... ssl`,
e.g. this repo's fe_https_term / prod/conf.d/11-fe-https-term.cfg) -- never
at an SNI-*passthrough* frontend (fe_https_passthrough): HAProxy never
presents a cert there at all, so there's nothing to cross-check.

Usage:
    check-acme-domains.py --domains prod/revoweb_domains.txt \\
        --frontend prod/conf.d/11-fe-https-term.cfg

Exit status: 0 if every domain and every ACL is matched by the other side,
1 if any drift was found, 2 on a usage/parse error.
"""
import argparse
import re
import sys
from collections import defaultdict

ACL_RE = re.compile(
    r"^\s*acl\s+(?P<name>\S+)\s+var\(txn\.txnhost\)\s+-m\s+(?P<method>beg|end|sub|str|reg)\s+(?:-i\s+)?(?P<pattern>.+?)\s*$"
)


def load_domains(path):
    """A line may be one domain, or several comma-separated domains that
    acme-agent.sh issues as SANs on one shared certificate -- check each
    individually against the ACLs regardless of how they're grouped into
    certs."""
    domains = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            for domain in line.split(","):
                domain = domain.strip()
                if domain:
                    domains.append(domain)
    return domains


def load_acls(path):
    """Return {acl_name: [(method, pattern), ...]}, skipping pfSense's
    aclcrt_* cert-bundle-selection helpers (redundant plumbing, not routes --
    see CLAUDE.md's "Real config in prod/")."""
    acls = defaultdict(list)
    with open(path) as f:
        for line in f:
            m = ACL_RE.match(line)
            if not m:
                continue
            name = m.group("name")
            if name.startswith("aclcrt_"):
                continue
            acls[name].append((m.group("method"), m.group("pattern")))
    return acls


def domain_matches_pattern(domain, method, pattern):
    d = domain.lower()
    p = pattern.lower()
    if method == "beg":
        return d.startswith(p)
    if method == "end":
        return d.endswith(p)
    if method == "sub":
        return p in d
    if method == "str":
        return d == p
    if method == "reg":
        try:
            return re.search(pattern, domain, re.IGNORECASE) is not None
        except re.error as e:
            print(f"warning: skipping unparseable regex ACL pattern {pattern!r}: {e}", file=sys.stderr)
            return False
    return False


def acl_matches_any_domain(patterns, domains):
    return any(domain_matches_pattern(d, method, pattern) for d in domains for method, pattern in patterns)


def domain_matches_any_acl(domain, acls):
    for name, patterns in acls.items():
        for method, pattern in patterns:
            if domain_matches_pattern(domain, method, pattern):
                return name
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--domains", action="append", required=True, metavar="PATH",
                         help="ACME_DOMAINS_FILE-format file (repeatable)")
    parser.add_argument("--frontend", action="append", required=True, metavar="PATH",
                         help="conf.d frontend file with Host-header ACLs (repeatable; TLS-terminating only)")
    args = parser.parse_args()

    domains = []
    for path in args.domains:
        try:
            domains.extend(load_domains(path))
        except OSError as e:
            print(f"error: can't read domains file {path}: {e}", file=sys.stderr)
            return 2

    acls = {}
    for path in args.frontend:
        try:
            file_acls = load_acls(path)
        except OSError as e:
            print(f"error: can't read frontend file {path}: {e}", file=sys.stderr)
            return 2
        for name, patterns in file_acls.items():
            acls.setdefault(name, []).extend(patterns)

    if not domains:
        print("warning: no domains loaded (empty or all-comment file(s))", file=sys.stderr)
    if not acls:
        print("warning: no Host-header ACLs found in frontend file(s) -- wrong file, or a passthrough frontend?", file=sys.stderr)

    orphan_domains = [d for d in domains if domain_matches_any_acl(d, acls) is None]
    uncovered_acls = {name: patterns for name, patterns in acls.items() if not acl_matches_any_domain(patterns, domains)}

    if orphan_domains:
        print(f"Domains with no matching route ({len(orphan_domains)}):")
        for d in orphan_domains:
            print(f"  {d}")
        print()

    if uncovered_acls:
        print(f"Routes with no matching cert ({len(uncovered_acls)}):")
        for name, patterns in sorted(uncovered_acls.items()):
            pat_str = ", ".join(f"-m {m} {p}" for m, p in patterns)
            print(f"  {name}: {pat_str}")
        print()

    if not orphan_domains and not uncovered_acls:
        print(f"OK: {len(domains)} domain(s) and {len(acls)} route(s) fully cross-matched.")
        return 0

    print(f"Checked {len(domains)} domain(s) against {len(acls)} route(s): "
          f"{len(orphan_domains)} orphan domain(s), {len(uncovered_acls)} uncovered route(s).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
