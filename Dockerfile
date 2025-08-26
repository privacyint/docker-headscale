###################
# BUILD PREP
###################
# Tool version arguments
# Bump these every time there is a new release.
# We're pulling these from github source, don't forget to bump the checksum!
ARG HEADSCALE_VERSION="0.26.1"
ARG HEADSCALE_SHA256="5012577e6fc5d4234aab7b4be0d6e271ea1a4ec38521a8aa472f80ea1fe81cba"

ARG LITESTREAM_VERSION="0.3.13"
ARG LITESTREAM_SHA256="eb75a3de5cab03875cdae9f5f539e6aedadd66607003d9b1e7a9077948818ba0"

# No checksum needed for these tools, we pull from official images
ARG CADDY_VERSION="2.10.2"
ARG MAIN_IMAGE_ALPINE_VERSION="3.22.1"
ARG HEADSCALE_ADMIN_VERSION="0.26.0"

# github download links
# These should never need adjusting unless the URIs change
ARG HEADSCALE_DOWNLOAD_URL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64"
ARG LITESTREAM_DOWNLOAD_URL="https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-amd64.tar.gz"

###################
# BUILD PROCESS
###################

# Build caddy with Cloudflare DNS support
FROM caddy:${CADDY_VERSION}-builder AS caddy-builder
    # Set SHELL flags for RUN commands to allow -e and pipefail
    # Rationale: https://github.com/hadolint/hadolint/wiki/DL4006
    SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

    RUN xcaddy build \
        --with github.com/caddy-dns/cloudflare

# Docker hates variables in COPY, apparently. Hello, workaround.
FROM goodieshq/headscale-admin:${HEADSCALE_ADMIN_VERSION} AS admin-gui

# Build our main image
FROM alpine:${MAIN_IMAGE_ALPINE_VERSION}
    # Set SHELL flags for RUN commands to allow -e and pipefail
    # Rationale: https://github.com/hadolint/hadolint/wiki/DL4006
    SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

    # Import our "global" `ARG` values into this stage
    ARG HEADSCALE_DOWNLOAD_URL
    ARG HEADSCALE_SHA256
    ARG LITESTREAM_DOWNLOAD_URL
    ARG LITESTREAM_SHA256

    # Upgrade system and install various dependencies
    # - BusyBox's wget isn't reliable enough
    # - I'm gonna need a better shell
    # - gettext provides `envsubst` for templating
    # hadolint ignore=DL3018,SC2086
    RUN BUILD_DEPS="wget"; \
        RUNTIME_DEPS="bash gettext"; \
        apk --no-cache upgrade; \
        apk add --no-cache --virtual BuildTimeDeps ${BUILD_DEPS}; \
        apk add --no-cache ${RUNTIME_DEPS}

    # Copy caddy from the first stage
    COPY --from=caddy-builder /usr/bin/caddy /usr/local/bin/caddy
    # Caddy smoke test
    RUN [ "$(command -v caddy)" = '/usr/local/bin/caddy' ]; \
        caddy version

    # Headscale
    RUN set -ex; { \
            wget --retry-connrefused \
                 --waitretry=1 \
                 --read-timeout=20 \
                 --timeout=15 \
                 -t 0 \
                 -q \
                 -O headscale \
                 ${HEADSCALE_DOWNLOAD_URL} || { \
                    echo "Failed to download Headscale from ${HEADSCALE_DOWNLOAD_URL}"; \
                    exit 1; \
                }; \
            echo "${HEADSCALE_SHA256} *headscale" | sha256sum -c - >/dev/null 2>&1; \
            chmod +x headscale; \
            mv headscale /usr/local/bin/; \
        }; \
        # Headscale smoke test
        [ "$(command -v headscale)" = '/usr/local/bin/headscale' ]; \
        headscale version;
    
    # Litestream
    RUN set -ex; { \
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
        # Litestream smoke test
        [ "$(command -v litestream)" = '/usr/local/bin/litestream' ]; \
        litestream version;
    
    # Headscale web GUI
    COPY --from=admin-gui /app/admin/ /admin-gui/admin/
    
    # Remove build-time dependencies
    RUN apk del BuildTimeDeps

    # Copy configuration templates
    COPY ./templates/headscale.template.yaml /etc/headscale/config.yaml
    COPY ./templates/litestream.template.yml /etc/litestream.yml
    COPY ./templates/Caddyfile-http.template /etc/caddy/Caddyfile-http
    COPY ./templates/Caddyfile-https.template /etc/caddy/Caddyfile-https

    # Copy and setup scripts into a safe bin directory
    COPY --chmod=755 ./scripts/ /usr/local/bin/

    # Default HTTPS port - override with $PUBLIC_LISTEN_PORT environment variable
    EXPOSE 443

    # Health check to ensure services are running
    HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
        CMD headscale version && caddy version || exit 1

    ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]
