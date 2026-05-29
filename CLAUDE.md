# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A container image build for **HAProxy 3.3 (AWS-LC TLS) + HAProxy Data Plane API on UBI 10**, designed to run unprivileged under OpenShift's restricted SCC (arbitrary UID). There is no application code — the "source" is a `Containerfile`, shell entrypoints, and HAProxy/Data Plane API configuration. All build artifacts live under `ubi10/`.

## Build and run

Build context is the `ubi10/` directory (the `COPY scripts/`, `COPY conf.d/`, etc. paths are relative to it):

```bash
cd ubi10
podman build -f Containerfile -t haproxy-ubi10:latest .
```

Run locally:

```bash
podman run --rm -p 8080:8080 -p 8443:8443 -p 8404:8404 -p 5555:5555 haproxy-ubi10:latest
```

Exposed ports: `8080` (http frontend), `8443`/`8444` (https), `8404` (stats), `5555` (Data Plane API). All non-privileged so no added capabilities are needed under OpenShift.

There is no test suite, linter, or CI. The only validation is `haproxy -c` (config check), which the entrypoints and `haproxy-reload.sh` run before (re)starting.

## Architecture

### Two-stage Containerfile (`ubi10/Containerfile`)
- **builder stage** (`ubi10/ubi` full) installs `haproxy-awslc` from the HAProxyTech RHEL repo into an `--installroot /tmp/rootfs`, importing the HAProxy community GPG key first.
- **final stage** (`ubi10/ubi-minimal`) copies that rootfs in, then *also* re-installs `haproxy-awslc` and the Data Plane API RPM directly. The `ENV HAPROXY_*_DIR` block is the source of truth for every path the image uses.
- **OpenShift compatibility is enforced in the Dockerfile, not at runtime:** writable dirs are `chgrp -R 0` + `chmod -R g=u` (group root, group mirrors owner perms) with the setgid bit on directories. When adding a new writable path, add it to all three of the `mkdir`/`chgrp`/`chmod` lists or it will break under a random UID.
- `Containerfile.orig` (single-stage, `microdnf install haproxy`) and `Containerfile.partial` are earlier iterations kept for reference; `Containerfile` is the live one.

### Scripts (`ubi10/scripts/`)
- **`container-entrypoint-dataplane.sh`** is the `ENTRYPOINT`. It supervises the processes in one container: starts `haproxy -W -db` in the background, waits for the admin socket + pidfile to appear, then starts `dataplaneapi`, and (when `ACME_ENABLED=true`) launches the ACME agent. It installs a `TERM`/`INT` trap that tears them down, and `wait -n`s on **haproxy + dataplaneapi only** so the container exits if either of those dies. It also honors `CMD`/`podman run` overrides: leading-`-` args (the default `CMD`) are HAProxy flags; a non-`haproxy` first arg (e.g. `sh`) is `exec`'d verbatim, bypassing supervision.
- **`acme-agent.sh`** is the optional DNS-01 cert agent (background daemon). It drives `acme.sh --dns dns_porkbun` to issue/renew certs for `ACME_DOMAINS`, looping every `ACME_RENEW_INTERVAL`. It is deliberately self-healing and NOT in the `wait -n` set — its death must not kill the container. Config/account/cert state lives in `LE_CONFIG_HOME=/etc/haproxy/acme`, which **must be a persistent volume** or every restart re-issues and hits Let's Encrypt rate limits.
- **`acme-deploy-dataplane.sh`** is acme.sh's `--reloadcmd`: it concatenates fullchain+key into a PEM and pushes it to the Data Plane API SSL storage (`PUT .../storage/ssl_certificates/{name}?force_reload=true`, falling back to `POST` on 404), which writes it into `ssl_certs_dir` (= the certs dir the `fe_https` bind loads) and triggers a hitless reload.
- **`haproxy-reload.sh`** is invoked *by the Data Plane API* (see `dataplaneapi.yaml` `reload_cmd`/`restart_cmd`). It runs `haproxy -c` then `kill -USR2 $(cat pidfile)` for a hitless reload. The Data Plane API edits config and calls this rather than restarting the container.

### Config model
HAProxy has no in-file `include`; the image passes multiple `-f` arguments instead. `CMD` is `-f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/`, so `conf.d/*.cfg` fragments are merged in lexical order (`10-frontends.cfg`, `20-backends.cfg`, ...).
- `haproxy.cfg` — `global`/`defaults` plus the `userlist dataplaneapi` that authenticates the API (default creds `admin`/`change-me` — change before any real use).
- `conf.d/` — frontends and backends, split by numeric prefix.
- `dataplaneapi.yaml` — Data Plane API config; its `transaction_dir`/`maps_dir`/`certs_dir` paths must line up with the `HAPROXY_*_DIR` env vars and the dirs created in the Containerfile.

### `haproxy.cfg.pfsense` (repo root)
A large auto-generated config exported from a pfSense HAProxy package. It is a **reference/source** for porting real frontends, backends, and ACLs into the `conf.d/` layout — not consumed by the build. It contains hashed user credentials; do not copy those into the image.

## Conventions
- Keep all path definitions centralized in the Containerfile `ENV` block and reference them; don't hardcode divergent paths in scripts or yaml.
- Any new writable directory must be group-0 / `g=u` to stay arbitrary-UID safe.
- Validate config changes with `haproxy -c -f haproxy.cfg -f conf.d/` before assuming a build/reload will succeed.
