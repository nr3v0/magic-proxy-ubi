# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Magic Proxy UBI** — a container image build for **HAProxy 3.3 (AWS-LC TLS) + HAProxy Data Plane API on UBI 10**, designed to run unprivileged (non-root) as a standalone container, e.g. a drop-in replacement for the pfSense HAProxy package. There is no application code — the "source" is a `Containerfile`, shell entrypoints, and HAProxy/Data Plane API configuration. All build artifacts live under `ubi10/`.

## Build, lint, and test

Use the root `Makefile` (it invokes podman with the correct build context and `--format docker`, which OCI format silently drops the `HEALTHCHECK` from):

```bash
make build   # podman build --format docker -f ubi10/Containerfile -t magic-proxy-ubi:latest ubi10
make lint    # sh -n over ubi10/scripts/*.sh
make test    # build, then boot a container with dummy ACME creds/domains, assert the agent starts, tear down
make clean   # remove test-only artefacts (ubi10/test-dummy-domains.txt, ubi10/test-acme-data/)
```

`ubi10/conf.d/` holds only the tracked demo frontend/backend config (`10-frontends.cfg`/`20-backends.cfg`) and is baked into the image as-is — no staging step. Real per-deployment config lives in `prod/conf.d/` (gitignored, never baked in; see "Real config in `prod/`" below) and is applied at runtime by **mounting it over the image's `/etc/haproxy/conf.d/`**, which is declared `VOLUME`d in the Containerfile specifically so that mount masks the baked-in demo:

```bash
podman run --rm -v $(pwd)/prod/conf.d:/etc/haproxy/conf.d:Z \
  -p 8080:8080 -p 8443:8443 -p 8444:8444 -p 6443:6443 -p 22623:22623 -p 8404:8404 -p 5555:5555 \
  magic-proxy-ubi:latest
```

Run locally with the baked-in demo instead (no mount):

```bash
podman run --rm -p 8080:8080 -p 8443:8443 -p 8404:8404 -p 5555:5555 magic-proxy-ubi:latest
```

Exposed ports: `8080` (http), `8443` (https, TLS-terminating), `8444` (https, SNI-passthrough — only meaningful with the real config mounted, see below), `6443`/`22623` (OpenShift api-server/machine-config-server passthrough, same caveat), `8404` (stats), `5555` (Data Plane API). All non-privileged so no added capabilities are needed.

`.github/workflows/ci.yml` runs on push/PR: a `lint` job (`sh -n` plus ShellCheck, `severity: error`, over `ubi10/scripts`) and a `build` job (image build, `haproxy -c` config check inside the image, then a smoke test that curls `/stats` until it's up). There's no application test suite beyond that — correctness is verified by `haproxy -c` (run by the entrypoints and `haproxy-reload.sh` before every (re)start) and the CI smoke test.

## Architecture

### Two-stage Containerfile (`ubi10/Containerfile`)
- **builder stage** (`ubi10/ubi` full) installs `haproxy-awslc` from the HAProxyTech RHEL repo into an `--installroot /tmp/rootfs`, importing the HAProxy community GPG key first.
- **final stage** (`ubi10/ubi-minimal`) copies that rootfs in, then *also* re-installs `haproxy-awslc` and the Data Plane API RPM directly. The `ENV HAPROXY_*_DIR` block is the source of truth for every path the image uses.
- **Non-root / any-UID support is enforced in the Dockerfile, not at runtime:** writable dirs are `chgrp -R 0` + `chmod -R g=u` (group root, group mirrors owner perms) with the setgid bit on directories. When adding a new writable path, add it to all three of the `mkdir`/`chgrp`/`chmod` lists or it will break under a random UID.
- `Containerfile.orig` (single-stage, `microdnf install haproxy`) and `Containerfile.partial` are earlier iterations kept for reference; `Containerfile` is the live one.

### Scripts (`ubi10/scripts/`)
- **`container-entrypoint-dataplane.sh`** is the `ENTRYPOINT`. It supervises the processes in one container: starts `haproxy -W -db` in the background, waits for the admin socket + pidfile to appear, then starts `dataplaneapi`, and (when `ACME_ENABLED=true`) launches the ACME agent. It installs a `TERM`/`INT` trap that tears them down, and `wait -n`s on **haproxy + dataplaneapi only** so the container exits if either of those dies. It also honors `CMD`/`podman run` overrides: leading-`-` args (the default `CMD`) are HAProxy flags; a non-`haproxy` first arg (e.g. `sh`) is `exec`'d verbatim, bypassing supervision.
- **`acme-agent.sh`** is the optional DNS-01 cert agent (background daemon). It drives `acme.sh --dns dns_porkbun` to issue/renew certs for domains specified either by `ACME_DOMAINS` (space-separated list) or `ACME_DOMAINS_FILE` (one domain per line, lines starting with # ignored) — **`ACME_DOMAINS_FILE` defaults to `/etc/haproxy/acme/acme_domains.txt`** (baked in from `ubi10/acme/acme_domains.txt`, ships with every line commented out, so `ACME_ENABLED=true` alone is a safe no-op). `load_domains()` only lets the file win when it actually has content after stripping comments/blanks — otherwise it falls back to `ACME_DOMAINS` — specifically so the default empty file doesn't silently shadow a bare `-e ACME_DOMAINS=...` override; don't revert that fallback without re-checking that case. It loops every `ACME_RENEW_INTERVAL`. It is deliberately self-healing and NOT in the `wait -n` set — its death must not kill the container. Config/account/cert state lives in `LE_CONFIG_HOME=/etc/haproxy/acme`, which **must be a persistent volume** or every restart re-issues and hits Let's Encrypt rate limits. **The domain list is entirely independent of `conf.d/`** — the script never reads `haproxy.cfg`/`conf.d/` at all. This is intentional, not a gap: `conf.d/`'s Host-header ACLs are mostly loose prefix/substring fragments (`-m beg`/`-m sub`, e.g. `heimdall.aps`), not literal FQDNs, so there's no reliable way to derive a domains list from them — see `tools/check-acme-domains.py` below for keeping the two in sync by hand instead of trying to eliminate the human step.
- **`acme-deploy-dataplane.sh`** is acme.sh's `--reloadcmd`: it concatenates fullchain+key into a PEM and pushes it to the Data Plane API SSL storage (`PUT .../storage/ssl_certificates/{name}?force_reload=true`, falling back to `POST` on 404), which writes it into `ssl_certs_dir` (= the certs dir the `fe_https` bind loads) and triggers a hitless reload.
- **`haproxy-reload.sh`** is invoked *by the Data Plane API* (see `dataplaneapi.yaml` `reload_cmd`/`restart_cmd`). It runs `haproxy -c` then `kill -USR2 $(cat pidfile)` for a hitless reload. The Data Plane API edits config and calls this rather than restarting the container.

### Config model
HAProxy has no in-file `include`; the image passes multiple `-f` arguments instead. `CMD` is `-f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/`, so `conf.d/*.cfg` fragments are merged in lexical order (`10-frontends.cfg`, `20-backends.cfg`, ...).
- `haproxy.cfg` — `global`/`defaults` plus the `userlist dataplaneapi` that authenticates the API (default creds `admin`/`change-me` — change before any real use).
- `conf.d/` — frontends and backends, split by numeric prefix.
- `dataplaneapi.yaml` — Data Plane API config; its `transaction_dir`/`maps_dir`/`certs_dir` paths must line up with the `HAPROXY_*_DIR` env vars and the dirs created in the Containerfile.

### Volumes
The Containerfile declares 7 `VOLUME`s: `conf.d`, `certs`, `acme`, `spoe`, `dataplane-storage`, `maps`, `backups` (all under `/etc/haproxy/`), each matching a `HAPROXY_*_DIR` ENV and a `dataplaneapi.yaml` `resources:`/`transaction:` key — see the comment above the `VOLUME` line in `ubi10/Containerfile` and the table in README.md's "Volume & Persistence Guidance" for what each holds and when to mount it. Without an explicit mount, Docker/Podman still pre-populate a fresh anonymous volume from the image's baked-in content on first run (so the demo and the bootstrap cert work with zero `-v` flags), but that state doesn't survive the container being removed and recreated. `conf.d` is the odd one out — mounting it *replaces* content (the demo vs. `prod/conf.d/`, see below); the other six are additive runtime state (ACME certs, Data Plane API-managed maps/backups/storage) that should be layered on top of whatever `conf.d` you're running. When adding a new writable path that needs the same treatment, add it to the Containerfile's `mkdir`/`chgrp`/`chmod` lists (see "Two-stage Containerfile" above) *and* to the `VOLUME` line.

### `haproxy.cfg.pfsense` (repo root, gitignored)
A large auto-generated config exported from a pfSense HAProxy package. It is a **reference/source** for porting real frontends, backends, and ACLs into the `conf.d/` layout — not consumed by the build. It contains hashed user credentials; kept local only, never committed.

### Real config in `prod/` — ported from pfSense, gitignored, mounted not baked
`prod/conf.d/be-*.cfg` (one file per app/cluster) and `prod/conf.d/1x-fe-*.cfg` (one file per real frontend) are a port of the actual pfSense HAProxy config from `haproxy.cfg.pfsense` — see `.gitignore` (`prod/` is entirely ignored: it's real internal topology and must not be committed). Unlike the demo, this never goes through the Containerfile at all — it's applied by bind-mounting `prod/conf.d/` over `/etc/haproxy/conf.d/` at `podman run` time (see "Build, lint, and test" above), which is what keeps real topology out of any built image. Regenerating or extending this port:

- **One backend file per app/cluster**, named `be-<app>.cfg` (e.g. `be-nextcloud.cfg`, `be-acm.cfg`). An OpenShift/SNO cluster's http+ingress-https+api-server+machine-config-server backend quadruplet all live together in one file per cluster, not split by kind. Backend/proxy names were kept as pfSense generated them (`be-<app>[-http|-ingress-https|-api-server|-machine-config-server]_ipvANY`) so they still match the `use_backend` references in the frontend files — don't rename one side without the other.
- **Frontends were restructured, not ported 1:1** — pfSense's `www-http-special` (pure subset of `www-http`, dropped) and its **4 separate TLS-offloading frontends** (`www-https-offloading`, `https-offloading-apps`, `www-https-offloading-home`, `www-https-offloading-revomusic`, each gated by a pfSense-generated `aclcrt_<frontend>` ACL tied to that frontend's own cert bundle) were merged into one `fe_https_term` on `:8443`, since this image's `bind ssl crt <dir>` already auto-selects the right cert per SNI — the `aclcrt_*` gating is now redundant and stripped except where it was a use_backend's *only* condition. **A real bug found in the source config was fixed, not blindly ported**: `www-https-offloading-home` had `use_backend be-acm-api-server_ipvANY if nextcloud-acl ...` — a copy-paste error routing Host-header `nextcloud*` traffic to the ACM api-server backend. Since `be-nextcloud_ipvANY` is `mode tcp` (SNI passthrough, reached via `fe_https_passthrough` on `:8444`) and can't be `use_backend`'d from the `mode http` `fe_https_term`, the fix added a second backend, `be-nextcloud-offload_ipvANY` (`mode http`, same server, re-encrypts instead of passing through) in `be-nextcloud.cfg`, and repointed the corrected ACL (renamed `nextcloud-offload-acl`) at it in `11-fe-https-term.cfg`.
- **Two distinct HTTPS traffic patterns, two frontends, two ports** — this is load-bearing, not a style choice: apps pfSense decrypted itself (Host-header ACLs, `var(txn.txnhost)`) go in `fe_https_term` (`:8443`, `mode http`, terminates TLS); apps that terminate their own TLS — mostly OpenShift routers, matched by pfSense via `req.ssl_sni` — go in `fe_https_passthrough` (`:8444`, `mode tcp`, never decrypts). Don't merge these two: a passthrough backend's cert isn't in `/etc/haproxy/certs/` and terminating it at `fe_https_term` would break it.
- **`fe_openshift_api` (`:6443`) / `fe_machine_config_server` (`:22623`)** are 1:1 ports of pfSense's `openshift-api-server`/`machine-config-server` frontends (`mode tcp`, SNI passthrough) — new ports for this image, added to the Containerfile `EXPOSE`.
- **`haproxy -c` was run against the full real config** (mounted at `/etc/haproxy/conf.d/`, see "Build, lint, and test") and two real bugs it caught were fixed, not just noted: (1) `10-fe-http.cfg` and `11-fe-https-term.cfg` referenced ACLs (`https`, `ospi-acl`) and `http-request ... if <acl>` conditions before those ACLs were defined — HAProxy requires top-down definition within a proxy, unlike the source pfSense frontends these were merged from, which had the acl block interleaved rather than only at the end; (2) `prod/conf.d/be-joan.cfg`, `be-octocam.cfg`, `be-octoprint.cfg`, `be-ospi.cfg`, `be-ospi-assets.cfg`, `be-privatebin.cfg`, `be-sonarr.cfg`, `be-transmission.cfg` all reference a `userlist RevowebUsers` for `http_auth` gating that pfSense defined once in its `global` section — never ported, since this image's `haproxy.cfg` has no equivalent. Added as `prod/conf.d/00-userlist.cfg` (gitignored with the rest of `prod/`, real hashed passwords).
- `fe_https_term`'s ACL priority is a best-effort concatenation of the 4 source frontends' lists (revomusic, apps, home, offloading order) — since each hostname mapped to exactly one of the 4 in the source, real collisions are unlikely but unverified. `fe_https_passthrough` dropped its pfSense default (which chained to the offloading frontends); an unmatched SNI on `:8444` is now refused outright rather than falling through.
- **`prod/conf.d/15-fe-stats.cfg`** — pfSense's own stats setup (`HAProxy_stats_ssl_frontend`) bound a specific VIP on SSL and was treated as plumbing, not an app, so nothing on `:8404` existed when only `prod/conf.d/` was mounted, and the Containerfile's `HEALTHCHECK` (curls `127.0.0.1:8404/stats`) always reported the container unhealthy even though HAProxy itself was fine. Rather than port pfSense's SSL/VIP-bound version, this just mirrors the demo's plain `fe_stats` (`ubi10/conf.d/10-frontends.cfg`) — confirmed the container reports `healthy` with `prod/conf.d/` mounted.
- **The demo and the real port will conflict if both end up loaded together** — both try to bind `*:8080`/`*:8443`. Mounting `prod/conf.d/` over `/etc/haproxy/conf.d/` at runtime (as documented above) fully replaces the baked-in demo rather than merging with it, so this is a non-issue as long as `prod/conf.d/` is mounted as a directory (not individual files) and nothing else copies demo files alongside it.
- Server lines had `resolvers globalresolvers` and `load-server-state-from-file global` stripped (this image doesn't define a `resolvers`/`server-state-file` section); everything else (IPs, `check`, `ssl`/`verify none`, `balance`, timeouts) was kept as pfSense had it.

### `tools/check-acme-domains.py` — ACME domains vs. `conf.d/` ACL drift checker
Not part of the image or build — a local dev tool that cross-checks an `ACME_DOMAINS_FILE`-format file against a TLS-*terminating* frontend's Host-header ACLs (point it at `fe_https_term`/`11-fe-https-term.cfg`, never at `fe_https_passthrough` — HAProxy never presents a cert there, so there's nothing to check). Flags both directions of drift: a domain with no matching ACL (stale cert, nobody routes to it), and an ACL with no matching domain (real traffic would get the self-signed bootstrap cert instead of a real one). It deliberately doesn't try to *generate* a domains list — see the `acme-agent.sh` note above for why that's not reliable — only to flag when the hand-maintained list and the hand-maintained ACLs have drifted apart. Matching mirrors HAProxy's own ACL semantics per method (`beg`→prefix, `end`→suffix, `sub`→substring, `str`→exact, `reg`→regex `search`, case-insensitive); `aclcrt_*` ACLs are skipped (pfSense's own cert-bundle plumbing, not routes — see above). Run via `make check-acme-domains ACME_DOMAINS_FILE=prod/your-domains.txt` (no default for the domains file — it's real data under gitignored `prod/`, `FRONTEND` defaults to `prod/conf.d/11-fe-https-term.cfg`). Exit 0 = clean, 1 = drift found, 2 = usage/parse error.

### `examples/` — Quadlet systemd deployment
`haproxy-acme.container` + `haproxy-acme.service` are a Podman Quadlet unit for running the image as a systemd service (rootful), paired with `acme.env.example` and `domains.txt.example` as templates for the real (gitignored) env/domains files. This is the documented production deployment path (see README.md "Running as a systemd service"); update these examples if entrypoint env vars or volume paths change. A real Quadlet deployment should also add a `Volume=` line mounting `prod/conf.d/` (or wherever it's deployed) over `/etc/haproxy/conf.d/`, same as the `podman run -v` form above.

## Conventions
- Keep all path definitions centralized in the Containerfile `ENV` block and reference them; don't hardcode divergent paths in scripts or yaml.
- Any new writable directory must be group-0 / `g=u` to stay arbitrary-UID safe.
- Validate config changes with `haproxy -c -f haproxy.cfg -f conf.d/` before assuming a build/reload will succeed.
