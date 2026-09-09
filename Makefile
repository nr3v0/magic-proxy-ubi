.PHONY: build lint test clean check-acme-domains

IMAGE ?= magic-proxy-ubi:latest
# Build context is ubi10/ because the Containerfile COPYs are relative to it.
CONTEXT := ubi10
# `--format docker` is required so the embedded HEALTHCHECK is preserved
# (the default OCI format silently drops it).
BUILD_FORMAT ?= docker

# Build the image. ubi10/conf.d/ holds only the tracked demo frontend/backend
# config -- real per-deployment config lives in prod/conf.d/ (gitignored) and
# is never baked in; mount it over /etc/haproxy/conf.d/ at runtime instead
# (VOLUME in the Containerfile), see CLAUDE.md.
build:
	podman build --format $(BUILD_FORMAT) -f $(CONTEXT)/Containerfile -t $(IMAGE) $(CONTEXT)

# Run basic syntax checks on shell scripts
lint:
	@echo "Linting shell scripts..."
	@for f in ubi10/scripts/*.sh; do echo "  $$f"; sh -n "$$f" || exit 1; done
	@echo "Shell syntax check passed."

# Build, boot the container (no real ACME calls), confirm it starts, then tear down.
test: build
	@echo "Running test container..."
	@printf 'test1.example.com\ntest2.example.com\n' > ubi10/test-dummy-domains.txt
	@mkdir -p ubi10/test-acme-data
	@podman rm -f haproxy-test >/dev/null 2>&1 || true
	@podman run -d --name haproxy-test \
	  -v $$(pwd)/ubi10/test-dummy-domains.txt:/etc/haproxy/acme/domains.txt:ro,Z \
	  -v $$(pwd)/ubi10/test-acme-data:/etc/haproxy/acme:Z \
	  -e ACME_ENABLED=true \
	  -e ACME_CA=letsencrypt_test \
	  -e ACME_DOMAINS_FILE=/etc/haproxy/acme/domains.txt \
	  -e ACME_EMAIL=test@example.com \
	  -e PORKBUN_API_KEY=pk1_test \
	  -e PORKBUN_SECRET_API_KEY=sk1_test \
	  -p 8404:8404 -p 5555:5555 \
	  $(IMAGE)
	@sleep 5
	@( podman logs haproxy-test 2>&1 | grep -q "\[acme-agent\] starting" \
	   && echo "Container started successfully" ) \
	  || ( echo "Container failed to start"; podman logs haproxy-test; \
	       podman rm -f haproxy-test >/dev/null 2>&1; $(MAKE) clean; exit 1 )
	@podman rm -f haproxy-test >/dev/null 2>&1 || true
	@$(MAKE) clean
	@echo "Test completed."

# Clean up test artefacts
clean:
	rm -rf ubi10/test-dummy-domains.txt ubi10/test-acme-data

# Cross-check an ACME domains file against a TLS-terminating frontend's ACLs
# (see tools/check-acme-domains.py -- flags drift, doesn't fix it). Your real
# domains file lives under gitignored prod/, so there's no sane default here.
#   make check-acme-domains ACME_DOMAINS_FILE=prod/your-domains.txt
FRONTEND ?= prod/conf.d/11-fe-https-term.cfg
check-acme-domains:
	@if [ -z "$(ACME_DOMAINS_FILE)" ]; then \
		echo "Usage: make check-acme-domains ACME_DOMAINS_FILE=path/to/domains.txt [FRONTEND=path/to/fe.cfg]"; \
		exit 2; \
	fi
	python3 tools/check-acme-domains.py --domains $(ACME_DOMAINS_FILE) --frontend $(FRONTEND)
