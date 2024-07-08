# ---
# Tool version args
ARG HEADSCALE_VERSION="0.23.0-alpha12"
ARG HEADSCALE_SHA256="6fd8483672a19b119ac0bea5bb39ae85eb8900f1405689f52a579fa988d8839c"
ARG LITESTREAM_VERSION="0.3.13"
ARG LITESTREAM_SHA256="eb75a3de5cab03875cdae9f5f539e6aedadd66607003d9b1e7a9077948818ba0"
# Container version args
ARG CADDY_BUILDER_VERSION="2.8.4-builder"
ARG MAIN_IMAGE_ALPINE_VERSION="3.20.1"

###########
# ---
# Build caddy with Azure DNS support
FROM caddy:${CADDY_BUILDER_VERSION} AS caddy-builder

    RUN xcaddy build \
        --with github.com/caddy-dns/azure

# --- 
# Build our main image
FROM alpine:${MAIN_IMAGE_ALPINE_VERSION}

    # ---
    # import our "global" `ARG` values into this stage
    ARG HEADSCALE_VERSION
    ARG HEADSCALE_SHA256
    ARG LITESTREAM_VERSION
    ARG LITESTREAM_SHA256

    # ---
    # upgrade system and installed dependencies for security patches
    RUN --mount=type=cache,sharing=private,target=/var/cache/apk \
        set -eux; \
        apk upgrade

    # ---
    # Copy caddy from the first stage
    COPY --from=caddy-builder /usr/bin/caddy /usr/local/bin/caddy
    # smoke tests
    RUN [ "$(command -v caddy)" = '/usr/local/bin/caddy' ]; \
        caddy version

    # ---
    # copy headscale
    RUN --mount=type=cache,target=/var/cache/apk \
        --mount=type=tmpfs,target=/tmp \
        set -eux; \
        cd /tmp; \
        # Headscale
        { \
            wget -q -O headscale https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64; \
            echo "${HEADSCALE_SHA256} *headscale" | sha256sum -c - >/dev/null 2>&1; \
            chmod +x headscale; \
            mv headscale /usr/local/bin/; \
        }; \
        # Litestream
        { \
            wget -q -O litestream.tar.gz https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-amd64.tar.gz; \
            echo "${LITESTREAM_SHA256} *litestream.tar.gz" | sha256sum -c - >/dev/null 2>&1; \
            tar -xf litestream.tar.gz; \
            mv litestream /usr/local/bin/; \
            rm -f litestream.tar.gz; \
        }; \
        # smoke tests
        [ "$(command -v headscale)" = '/usr/local/bin/headscale' ]; \
        [ "$(command -v litestream)" = '/usr/local/bin/litestream' ]; \
        headscale version; \
        litestream version

    # ---
    # copy configuration and templates
    COPY ./templates/headscale.template.yaml /etc/headscale/config.yaml
    COPY ./templates/litestream.template.yml /etc/litestream.yml
    COPY ./templates/caddy.template.yaml /etc/caddy/Caddyfile
    COPY ./scripts/container-entrypoint.sh /container-entrypoint.sh

    ENTRYPOINT ["/container-entrypoint.sh"]
