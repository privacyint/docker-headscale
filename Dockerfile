###################
# BUILD PREP
###################
# Tool version arguments
# Bump these every time there is a new release.
# We're pulling these from github source, don't forget to bump the checksum!
ARG HEADSCALE_VERSION="0.28.0"
ARG HEADSCALE_SHA256="95f242a31003d60646d233b14a1acacac20d8f319886d0441df085cc3a920f2d"

ARG LITESTREAM_VERSION="0.5.11"
ARG LITESTREAM_SHA256="2f80fdb6b0a0ff7a116ee37adf02d3de8e977ef76e052b28a6690218f0f7ab55"

# We're building these from source, so we need to specify the versions here rather than hash
ARG HEADSCALE_ADMIN_ENDPOINT="/admin"
ARG HEADSCALE_ADMIN_REPO="https://github.com/privacyint/headscale-admin"
ARG HEADSCALE_ADMIN_VERSION="v0.28.0"
ARG HEADSCALE_ADMIN_NODE_VERSION="25"

# No checksum needed for these tools, we pull from official images
ARG CADDY_VERSION="2.11.3"
ARG MAIN_IMAGE_ALPINE_VERSION="3.23.4"

# github download links
# These should never need adjusting unless the URIs change
ARG HEADSCALE_DOWNLOAD_URL="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64"
ARG LITESTREAM_DOWNLOAD_URL="https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-x86_64.tar.gz"

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

# Build the admin GUI from source
FROM node:${HEADSCALE_ADMIN_NODE_VERSION}-alpine AS admin-gui
    # Set SHELL flags for RUN commands to allow -e and pipefail
    # Rationale: https://github.com/hadolint/hadolint/wiki/DL4006
    SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

    ARG HEADSCALE_ADMIN_REPO
    ARG HEADSCALE_ADMIN_VERSION
    ARG HEADSCALE_ADMIN_ENDPOINT

    RUN apk --no-cache upgrade; \
        apk add --no-cache --virtual BuildTimeDeps git;

    RUN git clone ${HEADSCALE_ADMIN_REPO} /app && \
        cd /app && \
        git checkout ${HEADSCALE_ADMIN_VERSION}
    WORKDIR /app

    ENV ENDPOINT="${HEADSCALE_ADMIN_ENDPOINT}"
    RUN npm install && npm run build;

    RUN mv /app/build /app${HEADSCALE_ADMIN_ENDPOINT}

    RUN apk del BuildTimeDeps

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
