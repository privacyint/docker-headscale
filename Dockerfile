# ---
# Tool version args
# Bump these every time there is a new release. Don't forget the checksum!
ARG HEADSCALE_VERSION="0.25.1"
ARG HEADSCALE_SHA256="d2cda0a5d748587f77c920a76cd1bf1ab429e5299ba5bc6b3dda90712721b45b"

ARG LITESTREAM_VERSION="0.3.13"
ARG LITESTREAM_SHA256="eb75a3de5cab03875cdae9f5f539e6aedadd66607003d9b1e7a9077948818ba0"

# ---
# Container version args
# Bump these every time there is a new release. No checksum needed.
ARG CADDY_VERSION="2.10.0"
ARG MAIN_IMAGE_ALPINE_VERSION="3.21.3"
ARG HEADSCALE_ADMIN_VERSION="0.25.6"

# ---
# Tool download links
# These should never need adjusting unless the URIs change
ARG HEADSCALE_DOWNLOAD_URL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64"
ARG LITESTREAM_DOWNLOAD_URL="https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-amd64.tar.gz"

###########
# LOGIC STARTS HERE
###########

# ---
# Build caddy with Cloudflare DNS support
FROM caddy:${CADDY_VERSION}-builder AS caddy-builder
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
    # Upgrade system and install various dependencies
    # - BusyBox's wget isn't reliable enough
    # - I'm gonna need a better shell
    # - We need GNU sed
    # hadolint ignore=DL3018,SC2086
    RUN BUILD_DEPS="wget"; \
        RUNTIME_DEPS="bash sed"; \
        apk --no-cache upgrade; \
        apk add --no-cache --virtual BuildTimeDeps ${BUILD_DEPS}; \
        apk add --no-cache ${RUNTIME_DEPS}

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
    COPY --from=admin-gui /app/admin/ /admin-gui/admin/
    
    # Remove build-time dependencies
    RUN apk del BuildTimeDeps

    # ---
    # copy configuration and templates
    COPY ./templates/headscale.template.yaml /etc/headscale/config.yaml
    COPY ./templates/litestream.template.yml /etc/litestream.yml
    COPY ./templates/caddy.http.template.yaml /etc/caddy/Caddyfile-http
    COPY ./templates/caddy.https.template.yaml /etc/caddy/Caddyfile-https
    COPY ./scripts/container-entrypoint.sh /container-entrypoint.sh

    ENTRYPOINT ["/container-entrypoint.sh"]
