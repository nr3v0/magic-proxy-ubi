# README.md

# OpenShift-friendly HAProxy on UBI 10

This bundle provides an OpenShift-friendly HAProxy container layout using `ubi10/ubi-minimal`, the packaged `haproxy` RPM, an entrypoint that enforces `/etc/haproxy/haproxy.cfg`, and optional fragment loading from `/etc/haproxy/conf.d` in lexical order.[web:31][web:32][file:48][web:61]

## Files

- `Containerfile` builds a two-stage image: a `ubi10/ubi` builder installs `haproxy-awslc` from the HAProxyTech repo, and the final `ubi10/ubi-minimal` stage adds the Data Plane API and `acme.sh`.
- `scripts/container-entrypoint-dataplane.sh` is the entrypoint: it supervises HAProxy and the Data Plane API (and the ACME agent when enabled), honors `CMD`/`podman run` arg overrides, and adds `-W -db` before launch.
- `scripts/acme-agent.sh` + `scripts/acme-deploy-dataplane.sh` implement the DNS-01 (Porkbun) certificate agent — see [ACME DNS-01 certificates](#acme-dns-01-certificates-porkbun).
- `haproxy.cfg` contains the base `global`/`defaults` and the Data Plane API `userlist`.
- `conf.d/10-frontends.cfg` and `conf.d/20-backends.cfg` show how to split frontends and backends into separate fragments.

## OpenShift behavior

The image is made arbitrary-UID friendly by making writable paths group-owned by `0` and mirroring owner permissions to the group, which aligns with common OpenShift guidance for restricted workloads.[web:32][web:41][web:56]

The container binds to `8080`, `8443`, and `8404` instead of privileged ports, which avoids the need for extra privileges in typical OpenShift deployments.[web:32]

## Build

```bash
podman build -f Containerfile -t haproxy-ubi10:latest .
```

## Run locally

```bash
podman run --rm -p 8080:8080 -p 8443:8443 -p 8404:8404 haproxy-ubi10:latest
```

## Config layout

HAProxy does not use an in-file `include` directive in the way some daemons do; instead, the entrypoint launches HAProxy with both the main file and the `conf.d` directory so fragments are read in order.[web:61][web:68]

Suggested layout:

```text
/etc/haproxy/
├── haproxy.cfg
└── conf.d/
    ├── 10-frontends.cfg
    └── 20-backends.cfg
```

## ACME DNS-01 certificates (Porkbun)

The image bundles [`acme.sh`](https://github.com/acmesh-official/acme.sh) and an
in-container agent that obtains and auto-renews TLS certificates using the
**DNS-01** challenge against **Porkbun**, then pushes each cert into HAProxy
through the Data Plane API (hitless reload). HAProxy's native ACME client only
supports HTTP-01, so DNS-01 (and wildcards) is handled by `acme.sh` instead.

Enable it with environment variables at runtime:

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `ACME_ENABLED` | yes | `false` | Set `true` to start the agent |
| `ACME_DOMAINS` | yes | – | Space-separated domains, e.g. `example.com *.example.com` |
| `PORKBUN_API_KEY` | yes | – | Porkbun API key (`pk1_...`) |
| `PORKBUN_SECRET_API_KEY` | yes | – | Porkbun secret key (`sk1_...`) |
| `ACME_EMAIL` | recommended | – | ACME account email |
| `ACME_CA` | no | `letsencrypt` | acme.sh CA |
| `ACME_RENEW_INTERVAL` | no | `43200` | Seconds between renewal checks |
| `DATAPLANE_URL` / `DATAPLANE_USER` / `DATAPLANE_PASS` | no | `http://127.0.0.1:5555` / `admin` / `change-me` | Data Plane API target for cert push |

Enable API access for the domain in the Porkbun control panel first.

```bash
podman run --rm \
  -p 8443:8443 -p 8404:8404 -p 5555:5555 \
  -e ACME_ENABLED=true \
  -e ACME_DOMAINS="example.com *.example.com" \
  -e ACME_EMAIL="you@example.com" \
  -e PORKBUN_API_KEY="pk1_..." \
  -e PORKBUN_SECRET_API_KEY="sk1_..." \
  -v haproxy-acme:/etc/haproxy/acme \
  haproxy-ubi10:latest
```

> **Persist `/etc/haproxy/acme`.** Account keys, issued certs, and renewal state
> live there. Without a volume, every restart re-issues certificates and will
> hit Let's Encrypt rate limits. The HTTPS frontend ships with a throwaway
> self-signed `bootstrap.pem` so `:8443` can bind before the first real cert
> arrives; HAProxy then selects the ACME cert by SNI.

## Notes

Whether `microdnf install haproxy` succeeds depends on the repositories exposed to the UBI 10 build environment; the container structure is valid, but some environments may require entitled or mirrored RPM repositories to resolve the package.[web:21][web:31]
