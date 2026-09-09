# README.md

# Magic Proxy UBI

**Magic Proxy UBI** is a standalone container image for **HAProxy 3.3 (AWS‑L​C TLS) + HAProxy Data Plane API** on **Red Hat Universal Base Image 10 (UBI10)**. The image runs unprivileged (as a non‑root user) and is designed to run standalone with Podman or Docker — for example, as a drop‑in replacement for the HAProxy package on pfSense.

It bundles:

* HAProxy from the HAProxyTech RPM repository (AWS‑L​C build)  
* HAProxy Data Plane API (REST API for live configuration)  
* `acme.sh` with the Porkbun DNS‑01 plugin for automated Let’s Encrypt (or other ACME) certificates  
* Small helper scripts for entrypoint, certificate deployment, and reloading  

All runtime configuration is driven by environment variables and mounted files, making the image suitable for simple deployments with `podman run`/`docker run` or a systemd unit.

---  

## Table of Contents
1. [Image Overview](#image-overview)  
2. [Building the Image](#building-the-image)  
3. [Running the Container](#running-the-container)  
4. [Configuration Reference](#configuration-reference)  
   - [General Settings](#general-settings)  
   - [ACME / Let’s Encrypt Settings](#acme--lets-encrypt-settings)  
   - [Data Plane API Settings](#data-plane-api-settings)  
5. [Volume & Persistence Guidance](#volume--persistence-guidance)  
6. [Usage Examples](#usage-examples)  
   - [Simple manual launch](#simple-manual-launch)  
   - [Using an env‑file and a domains file](#using-an-env-file-and-a-domains-file)  
   - [Updating domains at runtime](#updating-domains-at-runtime)  
   - [Running as a systemd service](#running-as-a-systemd-service)  
7. [Operational Notes](#operational-notes)  
8. [Versions & Dependencies](#versions--dependencies)  
9. [Continuous Integration](#continuous-integration)  
10. [Troubleshooting](#troubleshooting)  
11. [License](#license)  
    - [Third‑Party Components](#third-party-components)  

---  

<a name="image-overview"></a>
## Image Overview

| Layer | Content |
|-------|---------|
| **Base** (`ubi10/ubi-minimal`) | Single stage: imports the HAProxy community GPG key and installs `haproxy-awslc` directly from the HAProxyTech repository, adds the Data Plane API RPM, installs `acme.sh` (full tree, includes `dns_porkbun.sh`), creates required directories, sets correct permissions for arbitrary‑UID support, and copies in configuration files and scripts. |
| **Entrypoint** | `/usr/local/bin/container-entrypoint-dataplane.sh` – supervises HAProxy and the Data Plane API (and the ACME agent when enabled), honors `CMD`/`podman run` overrides, and adds `-W -db` before launching HAProxy. |
| **Exposed Ports** | `80` (HTTP), `443` (HTTPS – SNI based), `8404` (HAProxy stats), `5555` (Data Plane API). |

The image runs as a non‑root user: all writable directories are group‑owned by root (gid 0) with `g=u` permissions and the setgid bit, allowing any user in group 0 to write.

> **Binding 80/443 as non-root**: the `haproxy` binary has the `cap_net_bind_service` file capability set at build time (`setcap`), which lets it bind these privileged ports while still running as uid 1001. This capability is already part of Docker's/Podman's default container capability set, so no `--cap-add` flag is normally required; the run examples below include it anyway as a defensive, explicit statement of the requirement, in case your environment uses a hardened/custom capability profile that drops it.

---  

<a name="building-the-image"></a>
## Building the Image

```bash
# Clone the repo (if you haven’t already)
git clone https://github.com/yourorg/magic-proxy-ubi.git
cd magic-proxy-ubi

# Build (context is the ubi10/ directory)
podman build --format docker -f ubi10/Containerfile -t localhost/magic-proxy-ubi:latest ubi10
# (or use `docker build -f ubi10/Containerfile -t magic-proxy-ubi:latest ubi10`)
# (or simply: make build)
```

> **`--format docker`** is required with Podman so the embedded `HEALTHCHECK` is
> preserved — the default OCI image format silently drops it. Docker and
> `make build` handle this automatically.

The build is single-stage (built directly on `ubi10/ubi-minimal`) and produces a final image of roughly 245 MB.

---  

<a name="running-the-container"></a>
## Running the Container

The container expects the following minimal configuration to operate:

* **Configuration files** – the image ships with a basic `haproxy.cfg`, a `conf.d/` directory containing a simple frontend/backend example, and a Data Plane API config referencing those files.  
* **Persistent storage** – several paths under `/etc/haproxy/` hold state written at runtime by the ACME agent and the Data Plane API, and should be backed by a volume so that state survives container restarts (see [Volume & Persistence Guidance](#volume--persistence-guidance) below). Without any `-v`/`--mount` flags, each still works — Docker/Podman pre-populate a fresh anonymous volume from the image's existing content on first run — but that state doesn't persist across a container being removed and recreated.  

A minimal run command:

```bash
podman run --rm \
  --cap-add=NET_BIND_SERVICE \
  -p 80:80 -p 443:443 -p 8404:8404 -p 5555:5555 \
  magic-proxy-ubi:latest
```

This starts HAProxy with the bundled demo configuration and the Data Plane API listening on `localhost:5555`. No ACME agent is started unless you set `ACME_ENABLED=true` and provide the required credentials (see the next section).

---  

<a name="configuration-reference"></a>
## Configuration Reference

All settings are passed as environment variables (or sourced from an `--env-file`).  
Values marked **required** must be present for the respective feature to work; otherwise the container will still start but the related functionality will be disabled.

### General Settings

| Variable | Required? | Default | Description |
|----------|-----------|---------|-------------|
| `ACME_ENABLED` | **No** (but needed for ACME) | `false` | Set to `true` to launch the ACME agent alongside HAProxy and the Data Plane API. |

### ACME / Let’s Encrypt Settings

| Variable | Required? | Default | Description |
|----------|-----------|---------|-------------|
| `ACME_DOMAINS` | **Yes**, unless `ACME_DOMAINS_FILE` points at a file with real entries | – | Space‑separated list of domains for which to request/renew certificates (e.g. `"example.com *.example.com"`), used whenever `ACME_DOMAINS_FILE`'s file is empty/all‑comments (including the image's own default, below). |
| `ACME_DOMAINS_FILE` | **No** | `/etc/haproxy/acme/acme_domains.txt` | Path (inside the container) to a file containing one entry per line; lines beginning with `#` are ignored. Each line is its own independent certificate by default — list several domains comma‑separated on one line (e.g. `a.example.com, b.example.com`) to issue those together as SANs on a single shared certificate instead. The image ships this default file with everything commented out — `ACME_ENABLED=true` alone is a safe no‑op until you edit it in, mount your own file over it, point this elsewhere, or just set `ACME_DOMAINS`. If the file actually has entries, it takes precedence over `ACME_DOMAINS`. |
| `PORKBUN_API_KEY` | **Yes** (if ACME enabled) | – | Porkbun API key (`pk1_…`). |
| `PORKBUN_SECRET_API_KEY` | **Yes** (if ACME enabled) | – | Porkbun secret API key (`sk1_…`). |
| `ACME_EMAIL` | **Recommended** | – | Email address for ACME account registration (used with `--register-account`). |
| `ACME_CA` | **No** | `letsencrypt` | ACME CA endpoint URL. Use `letsencrypt_test` for the Let’s Encrypt staging environment to avoid hitting rate limits while testing. |
| `ACME_RENEW_INTERVAL` | **No** | `43200` (12 h) | How often (in seconds) the agent checks for certificate renewals and, if a domain file is used, polls for file‑modification changes. |
| `ACME_EXTRA_ARGS` | **No** | – | Extra flags passed verbatim to `acme.sh --issue` (e.g. additional validation or DNS options). |
| `DATAPLANE_URL` | **No** | `http://127.0.0.1:5555` | Base URL of the Data Plane API (used by the deploy hook). |
| `DATAPLANE_USER` | **No** | `admin` | Username for HTTP basic auth against the Data Plane API. |
| `DATAPLANE_PASS` | **No** | `change-me` | Password for HTTP basic auth against the Data Plane API. |

> **Important**: The ACME agent stores the account key, certificates, and renewal state under `/etc/haproxy/acme` (the value of `LE_CONFIG_HOME`). This directory **must** be backed by a persistent volume or bind‑mount; otherwise each container start will generate a new account and request fresh certificates, quickly exhausting Let’s Encrypt’s rate limits.

> **Note**: Setting `ACME_ENABLED=true` makes `acme-agent.sh` register an ACME account on your behalf (`acme.sh --register-account`) — that's *you*, the operator, agreeing to [Let's Encrypt's Subscriber Agreement](https://letsencrypt.org/repository/), not this project. It's worth a read; recent revisions added an explicit warranty that you're not located in a jurisdiction under comprehensive U.S. sanctions. Using `dns_porkbun` similarly puts you under Porkbun's API Terms of Service.

> **Note**: `ACME_DOMAINS`/`ACME_DOMAINS_FILE` is a plain, manually‑maintained list — the agent never reads `haproxy.cfg`/`conf.d/`, so adding a route to your config doesn't automatically request it a cert, and removing one doesn't stop renewing it. If you're maintaining a real (non‑demo) `conf.d/`, `tools/check-acme-domains.py` cross‑checks your domains file against a TLS‑terminating frontend's ACLs and flags drift in either direction (`make check-acme-domains ACME_DOMAINS_FILE=path/to/domains.txt`).

### Data Plane API Settings

The Data Plane API is configured via `/etc/haproxy/dataplaneapi.yaml` (mounted into the image). You normally do **not** need to change this file unless you want to alter the API port, authentication method, or storage paths. The relevant keys are:

| Key | Description |
|-----|-------------|
| `dataplaneapi.host` / `dataplaneapi.port` | Where the API binds (default `0.0.0.0:5555`). |
| `dataplaneapi.userlist.userlist` | Name of the `userlist` (defined in `haproxy.cfg`) used for basic auth — currently `dataplaneapi`. |
| `dataplaneapi.resources.ssl_certs_dir` | Directory where the deploy hook writes PEM files (must match the `ssl crt` directive in the frontend). |
| `haproxy.reload.reload_cmd` / `haproxy.reload.restart_cmd` | Commands executed after a successful certificate push (set to `/usr/local/bin/haproxy-reload.sh` for a hitless reload). |

---  

<a name="volume--persistence-guidance"></a>
## Volume & Persistence Guidance

The image declares the following as `VOLUME`s (see `ubi10/Containerfile`). Each corresponds to a `HAPROXY_*_DIR` environment variable and a `dataplaneapi.yaml` storage path; without an explicit mount, Docker/Podman still pre-populate a fresh anonymous volume from the image's baked-in content on first run, but that state is lost the moment the container is removed and recreated rather than just restarted:

| Path | Holds | Persist it if… |
|------|-------|-----------------|
| `/etc/haproxy/conf.d` | Frontend/backend config | You're running your own real config instead of the bundled demo (see `CLAUDE.md`'s "Real config in `prod/`" for this project's own pattern). Mounting here **replaces** the baked-in demo entirely. |
| `/etc/haproxy/acme` | ACME account key, per-domain certs, renewal state (`LE_CONFIG_HOME`) | **Always**, once `ACME_ENABLED=true` — otherwise every restart re-issues certs and you'll hit Let's Encrypt rate limits. |
| `/etc/haproxy/certs` | PEM files the `fe_https`-style bind loads (`ssl_certs_dir`) | Always, in step with `/etc/haproxy/acme` — this is where `acme-deploy-dataplane.sh` actually writes the certs HAProxy serves. |
| `/etc/haproxy/maps` | Live-editable HAProxy map files (`maps_dir`) | You manage maps via the Data Plane API and want edits to survive a restart. |
| `/etc/haproxy/backups` | The Data Plane API's last 5 config backups (`backups_dir`) | You want that backup history to survive a restart; not required for correct operation. |
| `/etc/haproxy/spoe` | SPOE agent config (`spoe_dir`) | You use SPOE and manage its config via the Data Plane API. |
| `/etc/haproxy/dataplane-storage` | Misc Data Plane API storage (`dataplane_storage_dir`) | Generally worth persisting alongside the others. |

For most real deployments, mount at least `/etc/haproxy/acme` and `/etc/haproxy/certs`; add the rest if you're actively managing maps/backups/SPOE through the Data Plane API.

To retain certificates and ACME account data between container restarts, mount a volume (or a host directory) at `/etc/haproxy/acme`. Example:

```bash
# Create named podman volumes (recommended)
podman volume create magic-proxy
podman volume create haproxy-certs

# Then run:
podman run -d \
  --cap-add=NET_BIND_SERVICE \
  -p 443:443 -p 8404:8404 -p 5555:5555 \
  -e ACME_ENABLED=true \
  -e ACME_DOMAINS="example.com *.example.com" \
  -e ACME_EMAIL="you@example.com" \
  -e PORKBUN_API_KEY=... \
  -e PORKBUN_SECRET_API_KEY=... \
  -v magic-proxy:/etc/haproxy/acme \
  -v haproxy-certs:/etc/haproxy/certs \
  magic-proxy-ubi:latest
```

If you prefer a host bind‑mount:

```bash
mkdir -p /srv/magic-proxy /srv/haproxy-certs
podman run -d \
  --cap-add=NET_BIND_SERVICE \
  -p 443:443 -p 8404:8404 -p 5555:5555 \
  -e ACME_ENABLED=true \
  -e ACME_DOMAINS="example.com *.example.com" \
  -e ACME_EMAIL="you@example.com" \
  -e PORKBUN_API_KEY=... \
  -e PORKBUN_SECRET_API_KEY=... \
  -v /srv/magic-proxy:/etc/haproxy/acme \
  -v /srv/haproxy-certs:/etc/haproxy/certs \
  magic-proxy-ubi:latest
```

Add `-v haproxy-maps:/etc/haproxy/maps`, `-v haproxy-backups:/etc/haproxy/backups`, `-v haproxy-spoe:/etc/haproxy/spoe`, and/or `-v haproxy-dataplane-storage:/etc/haproxy/dataplane-storage` the same way if you need those to persist too (see the table above).

The directory will contain:

* `account.conf` – the ACME account key and registration data.  
* `ca/` – ACME CA certificates (used by `acme.sh`).  
* `*/_ecc/` – per‑domain certificate material (private key, certificate, full chain, etc.).  

---  

<a name="usage-examples"></a>
## Usage Examples

### <a name="simple-manual-launch"></a>Simple manual launch (no ACME)

```bash
podman run --rm \
  --cap-add=NET_BIND_SERVICE \
  -p 80:80 -p 443:443 -p 8404:8404 -p 5555:5555 \
  magic-proxy-ubi:latest
```

*HAProxy* will serve the static frontend/backend defined in the image.  
The Data Plane API is available at `http://localhost:5555/v3/` (auth: `admin`/`change‑me`).  

### <a name="using-an-env-file-and-a-domains-file"></a>Using an env‑file and a domains file

```bash
# 1️⃣ Create a domains file (one per line, comments start with #)
cat > /opt/data/haproxy-domains.txt <<'EOF'
example.com
*.example.com
# a subdomain for a specific service
api.example.com
EOF

# 2️⃣ Create an environment file (keep this secret!)
cat > /opt/data/magic-proxy.env <<'EOF'
ACME_ENABLED=true
ACME_CA=letsencrypt
ACME_DOMAINS_FILE=/etc/haproxy/acme/domains.txt
ACME_EMAIL="you@example.com"
PORKBUN_API_KEY="pk1_YOUR_PUBLIC_KEY"
PORKBUN_SECRET_API_KEY="sk1_YOUR_SECRET_KEY"
EOF
chmod 600 /opt/data/magic-proxy.env   # restrict access

# 3️⃣ Run the container
podman run -d \
  --name magic-proxy \
  --env-file /opt/data/magic-proxy.env \
  -v /opt/data/haproxy-domains.txt:/etc/haproxy/acme/domains.txt:ro,z \
  -v magic-proxy:/etc/haproxy/acme \
  -v haproxy-certs:/etc/haproxy/certs \
  --cap-add=NET_BIND_SERVICE \
  -p 443:443 -p 8404:8404 -p 5555:5555 \
  magic-proxy-ubi:latest
```

*Explanation*  

* The domains file is mounted **read‑only** (`:ro`) and with the `z` flag for SELinux contexts if needed.  
* The `magic-proxy` named volume provides persistence for the ACME account key and renewal state; `haproxy-certs` persists the actual PEM files HAProxy serves (see [Volume & Persistence Guidance](#volume--persistence-guidance)).  
* The container will start the ACME agent, obtain/renew certificates for the listed domains, push them via the Data Plane API, and trigger a hitless reload whenever a new certificate is available.

### <a name="updating-domains-at-runtime"></a>Updating domains at runtime

Because the agent watches the domain file for changes (via file‑modification timestamp polling) and also responds to `SIGUSR1`, you can update the list without restarting the container:

#### Option A – Let the agent poll (default behavior)

Edit the file:

```bash
echo "new.example.com" >> /opt/data/haproxy-domains.txt
```

The agent will notice the change on its next `ACME_RENEW_INTERVAL` check (default 12 h) or sooner if you reduce that interval. It will then request a certificate for the new name and redeploy.

#### Option B – Trigger an immediate reload

Send `SIGUSR1` to the container:

```bash
podman kill -s SIGUSR1 magic-proxy
```

The handler in `acme-agent.sh` will immediately re‑read the domains file, rebuild the internal list, and proceed with the next issuance/renewal cycle (which happens right after the signal handler returns).

> **Note**: If you remove a domain from the file, the existing certificate will **not** be automatically deleted; it will simply no longer be renewed. To clean up unused certs you can delete the corresponding `*_ecc` directory under `/etc/haproxy/acme` and optionally remove the PEM from the Data Plane API storage via a manual `DELETE` request.

---  

<a name="running-as-a-systemd-service"></a>
### Running as a systemd service

Ready-to-use unit files live in [`examples/`](examples/):

* [`examples/magic-proxy.service`](examples/magic-proxy.service) – a classic systemd unit that wraps `podman run`.
* [`examples/magic-proxy.container`](examples/magic-proxy.container) – a [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) unit (the modern replacement for the deprecated `podman generate systemd`).
* [`examples/acme.env.example`](examples/acme.env.example) and [`examples/domains.txt.example`](examples/domains.txt.example) – starting points for your secrets/domains.

Classic unit, quick install:

```bash
sudo cp examples/magic-proxy.service /etc/systemd/system/
sudo mkdir -p /etc/magic-proxy
sudo cp examples/acme.env.example    /etc/magic-proxy/acme.env      # edit secrets
sudo cp examples/domains.txt.example /etc/magic-proxy/domains.txt
sudo chmod 600 /etc/magic-proxy/acme.env
sudo systemctl daemon-reload
sudo systemctl enable --now magic-proxy.service
```

Quadlet (rootful) install:

```bash
sudo cp examples/magic-proxy.container /etc/containers/systemd/
# ...create /etc/magic-proxy/{acme.env,domains.txt} as above...
sudo systemctl daemon-reload
sudo systemctl start magic-proxy.service
```

> Both units reference `ghcr.io/yourorg/magic-proxy-ubi:latest` — change the `Image=`/`IMAGE=` line to your registry path (or `localhost/magic-proxy-ubi:latest` for a locally built image).

---  

<a name="operational-notes"></a>
## Operational Notes

* **Startup time** – The first run may take a minute or more while the ACME agent registers an account, performs the DNS‑01 challenge (which involves creating TXT records in Porkbun, waiting for propagation, and validating with Let’s Encrypt), and then loads the certificate into HAProxy. Subsequent starts are nearly instantaneous if the certificate is already present and not near expiry.  
* **Logging** – All significant actions are logged to `stdout`/`stderr` and can be inspected with `podman logs -f <container>`. Look for prefixes `[acme-agent]` and `[acme-deploy]`.  
* **Health checks** – The image ships with a built-in `HEALTHCHECK` that curls the unauthenticated HAProxy stats endpoint (`http://127.0.0.1:8404/stats`); `podman ps` / `docker ps` will show `healthy` once HAProxy is serving. Point any external monitor at the same endpoint. To additionally verify TLS, open an SSL connection to `:443` and check the served certificate (`openssl s_client -servername <domain>`).  
* **Default user** – The container runs as uid **1001** / gid **0** by default (non-root). It also works under any UID you assign (e.g. `podman run --user`); all writable paths are group-0 / `g=u`.  
* **Scaling** – Because the agent stores its state in a shared volume, multiple replicas can safely run **as long as they share the same `/etc/haproxy/acme` and `/etc/haproxy/certs` volumes** (the certs a replica serves come from `/etc/haproxy/certs`, not directly from the ACME state). However, only one instance should perform the ACME issuance/renewal at a time to avoid race conditions; the current design uses file‑based locking inside `acme.sh` (it creates a lockfile in `$LE_WORKING_DIR`) which makes concurrent instances safe.  
* **Updating base images** – To pick up security patches, simply rebuild the image (`podman build …`) and redeploy. The application‑specific configuration (config files, volumes) remains unchanged.  

---  

<a name="versions--dependencies"></a>
## Versions & Dependencies

The image pins its major components as follows (see `ubi10/Containerfile`):

| Component | Version / Source | How it's pinned |
|-----------|------------------|-----------------|
| Base image (builder) | `registry.access.redhat.com/ubi10/ubi` | `FROM` tag |
| Base image (runtime) | `registry.access.redhat.com/ubi10/ubi-minimal` | `FROM` tag |
| HAProxy | **3.3.x** (AWS-LC build; `haproxy-awslc`), currently `3.3.10` | HAProxyTech repo `…/performance/rhel/ha33/el10/x86_64` — the `ha33` channel tracks the 3.3 stable branch, so the patch level moves forward on rebuild |
| HAProxy Data Plane API | **3.3.3** | `ENV DATAPLANE_VERSION=3.3.3` (exact RPM downloaded from the GitHub release) |
| acme.sh | `master` (latest, currently `3.1.x`) | `ARG ACME_SH_REF=master` |

**Reproducible / pinned builds.** For deterministic rebuilds, override the floating refs at build time:

```bash
podman build -f ubi10/Containerfile \
  --build-arg ACME_SH_REF=3.1.0 \
  -t magic-proxy-ubi:pinned ubi10
```

To pin HAProxy or the Data Plane API to an exact patch, edit the repo channel / `DATAPLANE_VERSION` in `ubi10/Containerfile`. Pinning the base images to a digest (`ubi10/ubi-minimal@sha256:…`) is recommended for production supply-chain guarantees.

Beyond reproducibility, pinning `ACME_SH_REF` away from the floating `master` default also gives you a defensible, exact record of which acme.sh (GPL‑3.0) source a given image was built from — see [`NOTICE`](NOTICE).

---  

<a name="continuous-integration"></a>
## Continuous Integration

Two layers of checks are provided:

* **`Makefile`** — local targets: `make lint` (shell `sh -n` syntax check), `make build` (build the image), `make test` (build + boot a container and confirm it starts), `make clean`.
* **GitHub Actions** ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) — on push/PR it runs the shell lint + ShellCheck, builds the image, validates the HAProxy config (`haproxy -c`), and smoke-tests that the container boots and the stats endpoint answers.

```bash
make lint     # fast syntax check, no build
make build    # podman build the image
make test     # build, run, verify startup, tear down
```

### Claude Code MCP server (optional, for contributors)

The repository ships a project-scoped [`.mcp.json`](.mcp.json) that registers the
**Perplexity docs** MCP server (`https://docs.perplexity.ai/mcp`). It is purely a
convenience for contributors using [Claude Code](https://claude.com/claude-code)
and has **no effect on the image or runtime**. On first use Claude Code will
prompt you to approve the server (project-defined MCP servers are not trusted
automatically). It contains no secrets and can be ignored or removed
(`claude mcp remove --scope project perplexity-docs`) if you don't use Claude Code.

---  

<a name="troubleshooting"></a>
## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Container exits immediately after start | Missing or incorrect ACME credentials (`PORKBUN_API_KEY`/`PORKBUN_SECRET_API_KEY`) when `ACME_ENABLED=true` | Verify the env vars are set and contain valid values; check container logs for `[acme-agent] ERROR: PORKBUN_API_KEY / PORKBUN_SECRET_API_KEY are not set`. |
| `acme-agent` reports “No domains configured” | `ACME_DOMAINS` isn't set and `ACME_DOMAINS_FILE` (default `/etc/haproxy/acme/acme_domains.txt`, shipped empty) has no real entries | Set `ACME_DOMAINS`, or mount/edit a domains file with real entries (uncommented, one per line) and correct read permissions (`ro` is fine). |
| Certificate issuance hangs or repeats “Pending. The CA is processing your order” | DNS propagation delay or Porkbun API failure | Check Porkbun API keys, ensure the domain’s API access is enabled in the Porkbun portal, and verify that the TXT records are visible via `dig TXT _acme-challenge.<domain> @<resolver>`. You can increase `ACME_RENEW_INTERVAL` to give more time between checks. |
| After renewal, HAProxy still serves the old certificate | The deploy hook failed to push the new cert or the reload didn’t happen | Look for `[acme-deploy]` lines in the logs. A `404` followed by a `201` indicates a create; a `200` indicates an update. If you see errors (e.g., authentication failure), verify `DATAPLANE_USER`/`DATAPLANE_PASS` and that the Data Plane API is reachable (`curl -u admin:change-me http://localhost:5555/v3/info`). |
| The container crashes with “permission denied” on a directory inside `/etc/haproxy/acme` | The volume is mounted with the wrong SELinux context, or the host directory is not writable by the container user (uid 1001 / gid 0, or whatever UID you run it as) | If using SELinux, add the `:Z` (or `:z` for shared) flag to the volume (`-v /host/path:/etc/haproxy/acme:Z`). Ensure the host directory is group-0 writable, e.g. `chgrp 0 <dir> && chmod g+rwX <dir>`. |
| `podman` reports “port already in use” | Another process is already bound to the host port you’re trying to map | Choose different host ports (e.g., `-p 8080:80 -p 8444:443`) or stop the conflicting service. |

---  

<a name="license"></a>
## License

This project is released under the **MIT License**. See the [`LICENSE`](LICENSE) file for details.

**Scope:** The MIT license covers the files in *this repository* — the build
definitions (`Containerfile`), shell scripts, configuration, examples, and
documentation. Container images built from it bundle third‑party software, each
under its own license (see below). Your MIT license does not relicense those
components, and their licenses do not relicense your repository files; they are
combined by mere aggregation.

<a name="third-party-components"></a>
### Third‑Party Components

Images built from this repository include the following components, governed by
their respective licenses:

| Component | License | Source |
|-----------|---------|--------|
| Red Hat Universal Base Image 10 (`ubi`, `ubi-minimal`) | Red Hat Universal Base Image End User License Agreement (UBI EULA) | <https://www.redhat.com/licenses/EULA_Red_Hat_Universal_Base_Image_English_20190422.pdf> |
| HAProxy (`haproxy-awslc`) | GPL‑2.0‑or‑later (portions LGPL‑2.1) | <https://github.com/haproxy/haproxy> |
| AWS‑LC (HAProxy's TLS/crypto backend — confirmed via `haproxy -vv`) | Apache‑2.0 OR ISC | <https://github.com/aws/aws-lc> |
| HAProxy Data Plane API | Apache‑2.0 | <https://github.com/haproxytech/dataplaneapi> |
| acme.sh | GPL‑3.0 | <https://github.com/acmesh-official/acme.sh> |

Redistribution of the **built image** is additionally subject to the Red Hat UBI
EULA. Individual packages installed from the UBI repositories carry their own
upstream licenses (mostly GPL/LGPL/MIT/BSD); run `rpm -qa --qf '%{NAME} %{LICENSE}\n'`
inside the image for the full per‑package list. See the [`NOTICE`](NOTICE) file
for a concise summary, including why HAProxy (GPL‑2.0‑*or‑later*) linking
against AWS‑LC (Apache‑2.0) doesn't need HAProxy's OpenSSL‑specific GPL
exception clause.

> **Note:** This is informational, not legal advice. For commercial
> redistribution, review the Red Hat UBI EULA and the component licenses directly.

---  

*Prepared with ❤️ for the self‑hosting and container‑native community.*  