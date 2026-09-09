# Deploying to QNAP Container Station

This deploys the image as a Container Station **Application** (Docker Compose), using
[`docker-compose.yml`](docker-compose.yml) in this directory. Written for **Container
Station 3.x** (the Compose-based "Create Application" flow found on current QTS/QuTS
hero releases).

## Prerequisites

* A QNAP NAS with Container Station 3.x installed.
* SSH access to the NAS (Control Panel → Network & File Services → Telnet/SSH → enable),
  needed to create the shared-folder tree with correct permissions. You *can* create
  folders via File Station instead, but File Station has no way to set the ownership
  this image needs — see [Permissions](#permissions) below.
* The image, either pulled from a registry you push it to, or built locally and loaded
  into Container Station (`podman build`/`docker build` this repo, `docker save`, then
  Container Station → Images → Import, if you're not publishing it anywhere).

## 1. Create the shared-folder tree

SSH into the NAS and create the directories `docker-compose.yml` expects (adjust the
base path for your actual volume/shared-folder layout — `/share/Container/` is QNAP's
usual default location for Container Station data):

```bash
mkdir -p /share/Container/magic-proxy-ubi/{conf.d,acme,certs,maps,backups,spoe,dataplane-storage}
```

<a name="permissions"></a>
### Permissions

This image runs as **UID 1001, GID 0** (not root) — see `CLAUDE.md`'s "Non-root /
any-UID support" note. A freshly-created QNAP shared folder is normally owned by
`admin`/`administrators` and not group-writable, which means HAProxy inside the
container won't even be able to **read** a bind-mounted directory, let alone write to
it. The failure is unambiguous — you'll see this in the container's log:

```
[ALERT] config : Cannot open configuration directory /etc/haproxy/conf.d/ : Permission denied
```

Fix it before starting the container:

```bash
chown -R 1001:0 /share/Container/magic-proxy-ubi
chmod -R g+rwX /share/Container/magic-proxy-ubi
```

If your NAS's shell doesn't let you `chown` to an arbitrary UID that isn't a real QNAP
user (some QTS versions restrict this), `chmod -R 777 /share/Container/magic-proxy-ubi` is
the blunter but reliable fallback.

## 2. Populate `conf.d/`

Mounting `conf.d/` **replaces** the image's baked-in demo config entirely (see
`CLAUDE.md`'s "Volumes" section) — an empty `conf.d/` means HAProxy starts with no
frontends or backends at all. Copy in either:

* **The bundled demo**, to confirm the deployment works first: copy `ubi10/conf.d/*.cfg`
  from this repo to `/share/Container/magic-proxy-ubi/conf.d/` on the NAS.
* **Your own real config** — same layout this project itself uses locally in `prod/conf.d/`
  (gitignored, never committed; see `CLAUDE.md`'s "Real config in `prod/`").

## 3. Import the Compose file

In Container Station: **Applications → Create → Create Application**, paste in the
contents of [`docker-compose.yml`](docker-compose.yml) (or upload the file), then:

1. Find-and-replace every `/share/Container/magic-proxy-ubi/...` path if you used a
   different base path in step 1.
2. Set `image:` to wherever you pushed the built image (or the locally-imported tag).
3. Edit the `environment:` block: change `DATAPLANE_PASS` from the placeholder, and
   fill in real ACME/Porkbun values if you're setting `ACME_ENABLED: "true"` (leave it
   `"false"` for a first test with the demo config).
4. Check the `ports:` list against your NAS's own admin UI ports (Control Panel →
   System → General → System Administration) — QTS itself commonly uses `8080` and/or
   `443`. Change the **left** side of any conflicting `HOST:CONTAINER` pair; the
   container-side port must stay as-is.

Deploy. Container Station will show the container's health status once the built-in
`HEALTHCHECK` (curls `:8404/stats`) starts passing.

## 4. Verify

From another machine on the LAN:

```bash
curl -I http://<nas-ip>:80/                      # HTTP frontend (with the demo config, expect a 503 — its placeholder backend isn't running)
curl -sk https://<nas-ip>:443/ -o /dev/null -w '%{http_code}\n'
curl -I http://<nas-ip>:8404/stats               # HAProxy stats page
curl -u admin:<your-DATAPLANE_PASS> http://<nas-ip>:5555/v3/services/haproxy/configuration/version
```

## Notes

* **Data Plane API exposure** — `:5555` has no TLS and is only as safe as
  `DATAPLANE_PASS`. The compose file's comment suggests binding it to
  `127.0.0.1:5555:5555` (SSH-tunnel or reverse-proxy to reach it) or dropping it from
  `ports:` if you don't need to manage HAProxy remotely through it.
* **Updating the image** — Container Station's Application view lets you pull a new
  image tag and recreate the container; since all state lives in the mounted
  directories from step 1, recreating the container is safe (matches this repo's own
  "the container is disposable, the volumes aren't" design).
* **ACME rate limits** — if you enable ACME, double-check `acme/` and `certs/` are
  actually persisted (not accidentally left un-mounted) before testing against
  production Let's Encrypt — use `ACME_CA: letsencrypt_test` (staging) first, same as
  this repo's own `make test` does.
* **Reusing this repo's Quadlet example instead** — `examples/magic-proxy.container`
  is the equivalent for a Linux host running Podman + systemd rather than QNAP
  Container Station; same volumes, different mechanism.
