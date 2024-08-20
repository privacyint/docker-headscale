# ---
# Tool version args
ARG HEADSCALE_VERSION="0.23.0-beta2"
ARG HEADSCALE_SHA256="5883f909c89c97d0d43371646ca3bd834d205037e3c09e816e70b68d7d34a2f4"
ARG HEADSCALE_ADMIN_VERSION="0.1.12b"
ARG LITESTREAM_VERSION="0.3.13"
ARG LITESTREAM_SHA256="eb75a3de5cab03875cdae9f5f539e6aedadd66607003d9b1e7a9077948818ba0"
# Container version args
ARG CADDY_BUILDER_VERSION="2.8.4-builder"
ARG MAIN_IMAGE_ALPINE_VERSION="3.20.2"
# Download links
ARG HEADSCALE_DOWNLOAD_URL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64"
ARG LITESTREAM_DOWNLOAD_URL="https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-amd64.tar.gz"

###########
# ---
# Build caddy with Cloudflare DNS support
FROM caddy:${CADDY_BUILDER_VERSION} AS caddy-builder
    # Set SHELL flags for RUN commands to allow -e and pipefail
    # Rationale: https://github.com/hadolint/hadolint/wiki/DL4006
    SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

    RUN xcaddy build \
        --with github.com/caddy-dns/cloudflare

# ---
# Docker hates variables in COPY, apparently. Hello, workaround.
FROM goodieshq/headscale-admin:${HEADSCALE_ADMIN_VERSION} AS admin-gui

# --- 
# Build our main image
FROM alpine:${MAIN_IMAGE_ALPINE_VERSION}
    # Set SHELL flags for RUN commands to allow -e and pipefail
    # Rationale: https://github.com/hadolint/hadolint/wiki/DL4006
    SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

    # ---
    # import our "global" `ARG` values into this stage
    ARG HEADSCALE_DOWNLOAD_URL
    ARG HEADSCALE_SHA256
    ARG LITESTREAM_DOWNLOAD_URL
    ARG LITESTREAM_SHA256

    # ---
    # Upgrade system
    RUN apk --no-cache upgrade
    # ---
    # Install build dependencies
    # - BusyBox's wget isn't reliable enough
    RUN apk add --no-cache \
            wget --virtual BuildTimeDeps
    # ---
    # Install runtime dependencies
    # - I'm gonna need a better shell
    RUN apk add --no-cache bash
    # - We need GNU sed
    RUN apk add --no-cache sed

    # ---
    # Copy caddy from the first stage
    COPY --from=caddy-builder /usr/bin/caddy /usr/local/bin/caddy
    # Caddy smoke test
    RUN [ "$(command -v caddy)" = '/usr/local/bin/caddy' ]; \
        caddy version

    # ---
    # Headscale
    RUN { \
            wget --retry-connrefused \
                 --waitretry=1 \
                 --read-timeout=20 \
                 --timeout=15 \
                 -t 0 \
                 -q \
                 -O headscale \
                 ${HEADSCALE_DOWNLOAD_URL} \
            ; \
            echo "${HEADSCALE_SHA256} *headscale" | sha256sum -c - >/dev/null 2>&1; \
            chmod +x headscale; \
            mv headscale /usr/local/bin/; \
        }; \
        # smoke test
        [ "$(command -v headscale)" = '/usr/local/bin/headscale' ]; \
        headscale version;
    
    # Litestream
    RUN { \
            wget --retry-connrefused \
                 --waitretry=1 \
                 --read-timeout=20 \
                 --timeout=15 \
                 -t 0 \
                 -q \
                 -O litestream.tar.gz \
                 ${LITESTREAM_DOWNLOAD_URL} \
            ; \
            echo "${LITESTREAM_SHA256} *litestream.tar.gz" | sha256sum -c - >/dev/null 2>&1; \
            tar -xf litestream.tar.gz; \
            mv litestream /usr/local/bin/; \
            rm -f litestream.tar.gz; \
        }; \
        # smoke test
        [ "$(command -v litestream)" = '/usr/local/bin/litestream' ]; \
        litestream version;
    
    # Headscale web GUI
    COPY --from=admin-gui /app/admin/ /data/admin-gui/admin/
    
    # Remove build-time dependencies
    RUN --mount=type=cache,target=/var/cache/apk \
        apk del BuildTimeDeps;

    # ---
    # copy configuration and templates
    COPY ./templates/headscale.template.yaml /etc/headscale/config.yaml
    COPY ./templates/litestream.template.yml /etc/litestream.yml
    COPY ./templates/caddy.template.yaml /etc/caddy/Caddyfile
    COPY ./scripts/container-entrypoint.sh /container-entrypoint.sh

    ENTRYPOINT ["/container-entrypoint.sh"]
