# Design Document: Magic Proxy UBI (HAProxy 3.3 on UBI 10, ACME DNS‑01 Agent)

## Project Overview
**Magic Proxy UBI** is a container image for **HAProxy 3.3 (AWS‑LC TLS) + HAProxy Data Plane API** built on **Red Hat Universal Base Image 10 (UBI10)**. The image is intended to run unprivileged (as a non‑root user) as a standalone container with Podman or Docker — for example, as a drop‑in replacement for the HAProxy package on pfSense. It bundles:

* HAProxy from the HAProxyTech RPM repository (AWS‑LC build)
* HAProxy Data Plane API (REST API for live configuration)
* `acme.sh` with the Porkbun DNS‑01 plugin for automated Let’s Encrypt (or other ACME) certificates
* Helper scripts: entrypoint, certificate deployment hook, and reload script

All runtime configuration is driven by environment variables and mounted files, making the image suitable for simple deployments with `podman run`/`docker run` or a systemd unit.

---

## Table of Contents
1. [Image Overview](#image-overview)
2. [Component Breakdown](#component-breakdown)
3. [Build Process](#build-process)
4. [Runtime Configuration](#runtime-configuration)
5. [Volume & Persistence Guidance](#volume--persistence-guidance)
6. [Usage Examples](#usage-examples)
7. [Operational Considerations](#operational-considerations)
8. [Security Considerations](#security-considerations)
9. [Change Log](#change-log)
10. [References](#references)

---

## 1. Image Overview
The final image contains:
- **HAProxy** (`/usr/sbin/haproxy`) – the load balancer/proxy.
- **Data Plane API** (`/usr/sbin/dataplaneapi`) – REST API for dynamic updates (certificates, maps, etc.).
- **acme.sh** (full tree) – ACME client with DNS‑01 support for Porkbun.
- **Entrypoint** (`container-entrypoint-dataplane.sh`) – supervises HAProxy, Data Plane API, and optionally the ACME agent.
- **Deploy hook** (`acme-deploy-dataplane.sh`) – called by `acme.sh --reloadcmd` to push new certificates to the Data Plane API.
- **Reload script** (`haproxy-reload.sh`) – performs a config test and sends `SIGUSR2` to HAProxy for a hitless reload.
- **Bootstrap certificate** – a self‑signed `bootstrap.pem` placed in `/etc/haproxy/certs/` so the HTTPS listener can start before the first real certificate is issued.

All writable directories are made group‑0 (`chgrp -R 0`) and group‑writable (`chmod -R g=u`) with the setgid bit on directories (`chmod g+s`) to allow the container to run as a non‑root user or under any UID you assign.

---

## 2. Component Breakdown

| Component | Location | Purpose |
|-----------|----------|---------|
| **Containerfile** | `Containerfile` | Multi‑stage Dockerfile that builds the image. |
| **Entrypoint** | `scripts/container-entrypoint-dataplane.sh` | Starts HAProxy (master‑worker), Data Plane API, and ACME agent (if enabled). Handles signal forwarding and graceful shutdown. |
| **ACME Agent** | `scripts/acme-agent.sh` | Runs `acme.sh` in a loop, performs DNS‑01 challenges via Porkbun, invokes the deploy hook on success/renewal. Supports domain specification via `ACME_DOMAINS` (space‑separated) **or** `ACME_DOMAINS_FILE` (one per line, `#` comments). Watches the domain file for changes (mtime poll) and reacts to `SIGUSR1` for immediate reload. |
| **Deploy Hook** | `scripts/acme-deploy-dataplane.sh` | Called by `acme.sh --reloadcmd`. Builds a PEM (fullchain + key) and `PUT`s it to the Data Plane API SSL storage (`/v3/services/haproxy/storage/ssl_certificates/{name}?force_reload=true`). Falls back to `POST` if the resource does not exist (HTTP 404). |
| **Reload Script** | `scripts/haproxy-reload.sh` | Executes `haproxy -c -f …` then `kill -USR2 $(cat /var/lib/haproxy/haproxy.pid)` for a hitless reload. Used by the Data Plane API’s `reload_cmd`/`restart_cmd`. |
| **Configuration Files** | `haproxy.cfg`, `conf.d/` | Base HAProxy configuration (global, defaults, userlist for Data Plane API). The `conf.d/` directory is intended for user‑provided snippets (frontends/backends). |
| **Data Plane API Config** | `dataplaneapi.yaml` | Basic API configuration (listener on `0.0.0.0:5555`, userlist `dataplaneapi`, storage directories, etc.). |
| **Bootstrap Certificate** | Generated at build time (`openssl req -x509 -newkey rsa:2048 …`) | Placed in `/etc/haproxy/certs/bootstrap.pem` to allow the HTTPS listener to start immediately. |

---

## 3. Build Process
The image uses a two‑stage build:

1. **Builder stage** (`ubi10/ubi`):
   * Updates the base, installs `dnf-plugins-core`, `curl`, `rpm`.
   * Imports the HAProxyTech GPG key.
   * Adds the HAProxyTech repository for version 3.3 (AWS‑LC) on RHEL 10.
   * Installs `haproxy-awslc` into an isolated root (`/tmp/rootfs`).
2. **Final stage** (`ubi10/ubi-minimal`):
   * Copies the builder rootfs.
   * Updates and installs runtime dependencies: `findutils procps-ng openssl ca-certificates tar gzip`.
   * Installs `haproxy-awslc` (again, to ensure the final image has the binary).
   * Downloads and installs the HAProxy Data Plane API RPM (version 3.3.3).
   * Installs `acme.sh` (full tree) from GitHub (`master` branch at build time) and verifies the presence of the `dns_porkbun.sh` plugin.
   * Generates a throwaway self‑signed certificate (`bootstrap.pem`) for the HTTPS listener.
   * Sets ownership and permissions on all writable directories (`chgrp -R 0`, `chmod -R g=u`, `find … -type d -exec chmod g+s {} \;`).
   * Copies in the configuration files and scripts.
   * Sets the entrypoint to `/usr/local/bin/container-entrypoint-dataplane.sh`.
   * Default CMD: `["-f", "/etc/haproxy/haproxy.cfg", "-f", "/etc/haproxy/conf.d/"]` (HAProxy with main config plus all `.conf` files in `conf.d/`).

The resulting image is tagged as `localhost/magic-proxy-ubi:latest` (or any name you choose when pushing to a registry).

---

## 4. Runtime Configuration
All configuration is done via environment variables and mounted files. The container expects a volume mounted at `/etc/haproxy/acme` for persistent ACME state (account keys, issued certificates, etc.).

### 4.1 Core Settings
| Variable | Default | Description |
|----------|---------|-------------|
| `ACME_ENABLED` | `false` | Set to `true` to start the ACME agent. |
| `ACME_CA` | `letsencrypt` | ACME CA to use (`letsencrypt` for production, `letsencrypt_test` for staging). |
| `ACME_DOMAINS` | *(empty)* | Space‑separated list of domains (e.g., `"example.com *.example.com"`). |
| `ACME_DOMAINS_FILE` | *(empty)* | Path to a file containing one domain per line (lines beginning with `#` are ignored). Overrides `ACME_DOMAINS` if set and readable. |
| `ACME_EMAIL` | *(empty)* | Optional email for ACME account registration/recovery notices. |
| `ACME_RENEW_INTERVAL` | `43200` (12 h) | Seconds between renewal checks. Also controls how often the domain file is polled for changes. |
| `DATAPLANE_URL` | `http://127.0.0.1:5555` | Base URL for the Data Plane API. |
| `DATAPLANE_USER` | `admin` | Username for Data Plane API basic auth. |
| `DATAPLANE_PASS` | `change‑me` | Password for Data Plane API basic auth. |
| `ACME_EXTRA_ARGS` | *(empty)* | Additional flags passed directly to `acme.sh --issue`. |
| `TZ` | *(host’s)* | Timezone for cron‑like logging inside the agent. |

### 4.2 How Domains Are Determined
The agent uses the following precedence:
1. If `ACME_DOMAINS_FILE` is set **and** the file is readable → read the file, strip comments/blank lines, split on newline.
2. Else if `ACME_DOMAINS` is non‑empty → split on whitespace.
3. Else → no domains; the agent idles (logs a message and sleeps in a loop).

When a domain file is used, the agent checks the file’s modification time (`stat -c %Y`) on each loop iteration (every `ACME_RENEW_INTERVAL` seconds). If the mtime has changed, it reloads the list, rebuilds the `acme.sh` `-d` arguments, and logs the change. This provides **runtime reload** without restarting the container.

Additionally, a `SIGUSR1` sent to the container (or to the agent’s PID inside) triggers an immediate reload of the domain list (re‑reading the file or environment variable) and proceeds with the next issuance/renewal cycle.

### 4.3 Example Environment Files
#### Simple (inline)
```bash
ACME_ENABLED=true
ACME_CA=letsencrypt
ACME_DOMAINS="example.com *.example.com"
ACME_EMAIL=you@example.com
ACME_RENEW_INTERVAL=86400
PORKBUN_API_KEY=pk1_...
PORKBUN_SECRET_API_KEY=sk1_...
```

#### File‑based domains
```bash
# domains.txt
example.com
*.example.com
# a comment line
sub.example.com
```

```bash
# acme.env
ACME_ENABLED=true
ACME_CA=letsencrypt
ACME_DOMAINS_FILE=/etc/haproxy/acme/domains.txt
ACME_EMAIL=you@example.com
ACME_RENEW_INTERVAL=86400
PORKBUN_API_KEY=pk1_...
PORKBUN_SECRET_API_KEY=sk1_...
```

Mount the file read‑only: `-v /host/path/domains.txt:/etc/haproxy/acme/domains.txt:ro`.

### 4.4 Updating Domains at Runtime
Because the agent polls the domain file’s mtime (or reacts to `SIGUSR1`), you can change the list without rebuilding or restarting the container:

* **File edit** – edit the mounted `domains.txt` (add/remove/comment lines). The next polling cycle (up to `ACME_RENEW_INTERVAL` seconds later) will detect the change, reload the list, and the subsequent renewal/issuance will use the new set.
* **Signal** – run `podman kill -s SIGUSR1 <container>` (or `docker kill -s SIGUSR1 <container>`) to force an immediate reread of the current file/environment.

> **Note:** Changing the set of domains does **not** automatically revoke or delete existing certificates. Certificates for removed domains will simply not be renewed upon expiry. To clean up, you can manually delete the corresponding `*_ecc` directory under `/etc/haproxy/acme` and optionally delete the certificate from the Data Plane API storage via a `DELETE` request.

---

## 5. Volume & Persistence Guidance
The directory `/etc/haproxy/acme` **must** be persisted across container restarts. It holds:
* The `acme.sh` account key and registration data (`account.conf`, `account.key`).
* Issued certificates and keys (under `*/_ecc/` subdirectories).
* Renewal metadata and temporary files.

**Without persistence**, every container start would cause the agent to register a new account and request new certificates, quickly hitting Let’s Encrypt rate limits.

**Recommended setup**:
```bash
# On the host, create a directory for persistent storage
mkdir -p /var/lib/haproxy-acme

# Run the container
podman run -d \
  --name haproxy-acme \
  --env-file /path/to/acme.env \
  -v /path/to/domains.txt:/etc/haproxy/acme/domains.txt:ro \
  -v /var/lib/haproxy-acme:/etc/haproxy/acme:Z \
  -p 8443:8443 -p 5555:5555 \
  localhost/magic-proxy-ubi:latest
```
*The `:z` label is for SELinux systems; adjust as needed.*

The HTTPS listener (`fe_https`) is configured to load all PEM files from `/etc/haproxy/certs/`. The deploy hook places each newly issued certificate there as `<sanitized_domain>.pem` (where `*` becomes `_`). HAProxy selects the appropriate certificate via SNI.

---

## 6. Usage Examples

### 6.1 Simple Manual Launch (for testing)
```bash
podman run --rm -it \
  -e ACME_ENABLED=true \
  -e ACME_CA=letsencrypt_test \
  -e ACME_DOMAINS="test.example.com" \
  -e ACME_EMAIL=test@example.com \
  -e PORKBUN_API_KEY=pk1_fake \
  -e PORKBUN_SECRET_API_KEY=sk1_fake \
  -p 8443:8443 -p 5555:5555 \
  localhost/magic-proxy-ubi:latest
```
*Use `letsencrypt_test` to avoid hitting rate limits during experimentation.*

### 6.2 Using an Env‑File and a Domains File (Production‑like)
```bash
# 1. Prepare files
mkdir -p /opt/haproxy/acme /opt/haproxy/domains
echo -e "example.com\n*.example.com" > /opt/haproxy/domains/sites.txt

cat > /opt/haproxy/acme.env <<'EOF'
ACME_ENABLED=true
ACME_CA=letsencrypt
ACME_DOMAINS_FILE=/etc/haproxy/acme/domains.txt
ACME_EMAIL=admin@example.com
ACME_RENEW_INTERVAL=86400
PORKBUN_API_KEY=pk1_YOUR_REAL_KEY
PORKBUN_SECRET_API_KEY=sk1_YOUR_REAL_SECRET
EOF
chmod 600 /opt/haproxy/acme.env

# 2. Run the container
podman run -d \
  --name haproxy-acme \
  --env-file /opt/haproxy/acme.env \
  -v /opt/haproxy/domains/sites.txt:/etc/haproxy/acme/domains.txt:ro \
  -v /opt/haproxy/acme:/etc/haproxy/acme:Z \
  -p 8443:8443 -p 8404:8404 -p 5555:5555 \
  localhost/magic-proxy-ubi:latest
```

### 6.3 Updating Domains at Runtime
*Edit the domains file*:
```bash
echo "new.sub.example.com" >> /opt/haproxy/domains/sites.txt
```
The agent will notice the change on its next poll (within `ACME_RENEW_INTERVAL` seconds) and request a certificate for the new name.

*Or trigger immediately*:
```bash
podman kill -s SIGUSR1 haproxy-acme
```

---

## 7. Operational Considerations
| Area | Detail |
|------|--------|
| **Logging** | All significant actions are logged to stdout/stderr; inspect with `podman logs -f <container>`. Look for prefixes `[acme-agent]` and `[acme-deploy]`. |
| **Health Checks** | *Liveness*: `curl -s -f http://localhost:5555/v3/info || exit 1`.<br>*Readiness*: Attempt an SSL connection to the HTTPS port and verify the certificate matches an expected name (`openssl s_client -connect localhost:8443 -servername example.com -servername …`). |
| **Updates** | To pick up base‑image OS or HAProxy patches, simply rebuild the image (`podman build …`) and redeploy. Your volumes and configuration remain unchanged. |
| **Scaling** | Multiple replicas can safely share the same `/etc/haproxy/acme` volume because `acme.sh` uses internal lockfiles (`$LE_WORKING_DIR/acme.sh.pid`, etc.) to prevent concurrent issuance collisions. |
| **Resource Usage** | The image is lightweight (< 200 MB). The agent runs as a background `sh` process; memory usage is minimal (< 10 MB). |
| **Backup** | Periodically snapshot the `/etc/haproxy/acme` volume (or the host directory it’s mounted to) to preserve account keys and certificates in case of catastrophic loss. |

---

## 8. Security Considerations
1. **Non‑root / any‑UID support** – All writable directories are group‑0 with `g=u` and setgid bits, allowing the container to run as a non‑root user or under any UID you assign.
2. **Secrets Handling** – Never embed `PORKBUN_API_KEY`/`PORKBUN_SECRET_API_KEY` in the image or in a public Git repository. Use `--env-file`, Podman/Docker secrets, or a secrets manager.
3. **Network Exposure** – The Data Plane API (`:5555`) is exposed only if you map the port. It is protected by basic auth (`admin`/`change‑me` by default). **Change these credentials** before production use.
4. **Certificate Private Keys** – Stored in `/etc/haproxy/acme/*_ecc/` with permissions `600` (owned by root inside the container). When the volume is mounted on the host, ensure the host’s filesystem respects these permissions or adjust via supplemental groups/SELinux labels.
5. **Minimal Privileges** – The container does **not** require any Linux capabilities; it runs as a regular (possibly unprivileged) user inside the namespace.
6. **Image Provenance** – The builder stage uses the official HAProxyTech RPMs and the official `acme.sh` GitHub repository. No third‑party binaries are fetched from unverified sources.

---

## 9. Change Log
| Date | Description |
|------|-------------|
| 2026‑05‑28 | Initial repository layout: `Containerfile`, basic scripts, `haproxy.cfg`, `README.md`. |
| 2026‑05‑29 | Added ACME agent (`acme-agent.sh`) and deploy hook (`acme-deploy-dataplane.sh`). Enabled `ACME_ENABLED` flag. |
| 2026‑05‑29 | Updated entrypoint to supervise HAProxy, Data Plane API, and ACME agent; added signal handling. |
| 2026‑05‑29 | Created `README.md` with usage instructions. |
| 2026‑05‑30 | Added domain‑file support (`ACME_DOMAINS_FILE`) and runtime reload via file‑mtime polling and `SIGUSR1` signal. |
| 2026‑05‑30 | Added `DESIGN.md` (this document) summarizing architecture and design decisions. |
| 2026‑05‑30 | Minor README updates to reflect new domain‑file usage and examples. |

---

## 10. References
- HAProxy Documentation: <https://www.haproxy.com/documentation/>
- HAProxy Data Plane API Guide: <https://github.com/haproxytech/dataplaneapi>
- acme.sh GitHub: <https://github.com/acmesh-official/acme.sh>
- Porkbun DNS‑01 hook for acme.sh: <https://github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_porkbun>
- Let’s Encrypt Rate Limits: <https://letsencrypt.org/docs/rate-limits/>

--- 

*This design document captures the evolution of the project as discussed in the project’s chat history and serves as a living reference for future development and maintenance.* 
