# ---
# Tool version args
ARG HEADSCALE_VERSION="0.23.0-alpha12"
ARG HEADSCALE_SHA256="6fd8483672a19b119ac0bea5bb39ae85eb8900f1405689f52a579fa988d8839c"
ARG HEADSCALE_ADMIN_VERSION="0.1.12b"
ARG HEADSCALE_ADMIN_SHA512="30af8ec4fafe069c8b91caf2066a254d1d1bc237e0ad0e8f169aaeac92b4506a"
ARG LITESTREAM_VERSION="0.3.13"
ARG LITESTREAM_SHA256="eb75a3de5cab03875cdae9f5f539e6aedadd66607003d9b1e7a9077948818ba0"
# Container version args
ARG CADDY_BUILDER_VERSION="2.8.4-builder"
ARG MAIN_IMAGE_ALPINE_VERSION="3.20.1"

###########
# ---
# Build caddy with Cloudflare DNS support
FROM caddy:${CADDY_BUILDER_VERSION} AS caddy-builder

    RUN xcaddy build \
        --with github.com/caddy-dns/cloudflare \
        --with github.com/crmejia/certmagic_sqlite3

# --- 
# Build our main image
FROM alpine:${MAIN_IMAGE_ALPINE_VERSION}

    # ---
    # import our "global" `ARG` values into this stage
    ARG HEADSCALE_VERSION
    ARG HEADSCALE_SHA256
    ARG HEADSCALE_ADMIN_VERSION
    ARG HEADSCALE_ADMIN_SHA512
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
    # Caddy smoke test
    RUN [ "$(command -v caddy)" = '/usr/local/bin/caddy' ]; \
        caddy version

    # ---
    # set up our environment
    RUN --mount=type=cache,target=/var/cache/apk \
        --mount=type=tmpfs,target=/tmp \
        set -eux; \
        cd /tmp; \
        # BusyBox's wget isn't reliable enough
        apk add wget; \
        # I'm gonna need a better shell, too
        apk add bash; \
        # We need GNU sed
        apk add sed;

    # Headscale
    RUN { \
            wget --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=15 -t 0 -q -O headscale https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64; \
            echo "${HEADSCALE_SHA256} *headscale" | sha256sum -c - >/dev/null 2>&1; \
            chmod +x headscale; \
            mv headscale /usr/local/bin/; \
        }; \
        # smoke test
        [ "$(command -v headscale)" = '/usr/local/bin/headscale' ]; \
        headscale version;
    
    # Litestream
    RUN { \
            wget --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=15 -t 0 -q -O litestream.tar.gz https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-amd64.tar.gz; \
            echo "${LITESTREAM_SHA256} *litestream.tar.gz" | sha256sum -c - >/dev/null 2>&1; \
            tar -xf litestream.tar.gz; \
            mv litestream /usr/local/bin/; \
            rm -f litestream.tar.gz; \
        }; \
        # smoke test
        [ "$(command -v litestream)" = '/usr/local/bin/litestream' ]; \
        litestream version;
    
    # Headscale web GUI
    RUN { \
            wget --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=15 -t 0 -q -O headscale-gui.tar.gz https://github.com/GoodiesHQ/headscale-admin/releases/download/v${HEADSCALE_ADMIN_VERSION}/admin.tar.gz; \
            echo "${HEADSCALE_ADMIN_SHA256} *headscale-gui.tar.gz" | sha256sum -c - >/dev/null 2>&1; \
            mkdir -p headscale-gui; \
            tar -xf headscale-gui.tar.gz -C headscale-gui; \
            mv headscale-gui /data/; \
            rm -f headscale-gui.tar.gz; \
        };
    
    # Remove build-time dependencies
    RUN --mount=type=cache,target=/var/cache/apk \
        apk del wget;

    # ---
    # copy configuration and templates
    COPY ./templates/headscale.template.yaml /etc/headscale/config.yaml
    COPY ./templates/litestream.template.yml /etc/litestream.yml
    COPY ./templates/caddy.template.yaml /etc/caddy/Caddyfile
    COPY ./scripts/container-entrypoint.sh /container-entrypoint.sh

    ENTRYPOINT ["/container-entrypoint.sh"]
