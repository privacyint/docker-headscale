# Headscale on an immutable Docker image

Deploy [Headscale][headscale-wob] using a "serverless" immutable docker image with real-time [Litestream][litestream-wob] database backup and (by default) inbuilt [Caddy][caddy-wob] SSL termination, using a miniscule [Alpine Linux][alpine-linux-wob] base image. Provides a stateless [headscale-admin][headscale-admin-wob] panel at `/admin/`.

## Included upstream versions

| Tool | Upstream Repository | Version |
|---|---|---|
| [`Alpine Linux`][alpine-linux-wob] | [Alpine Linux Repo][alpine-linux-repo] | [`v3.21.3`](https://git.alpinelinux.org/aports/log/?h=v3.21.3) |
| [`Headscale`][headscale-wob] | [Headscale Repo][headscale-repo] | [`v0.25.1`](https://github.com/juanfont/headscale/releases/tag/v0.25.1) |
| [`Headscale-Admin`][headscale-admin-wob] | [Headscale-Admin Repo][headscale-admin-repo] | [`v0.25.6`](https://github.com/GoodiesHQ/headscale-admin/releases/tag/v0.25.6) |
| [`Litestream`][litestream-wob] | [Litestream Repo][litestream-repo] | [`v0.3.13`](https://github.com/benbjohnson/litestream/releases/tag/v0.3.13) |
| [`Caddy`][caddy-wob] | [Caddy Repo][caddy-repo] | [`v2.9.1`](https://github.com/caddyserver/caddy/releases/tag/v2.9.1) |

## Versioning

Because of the mix of upstream tools included, this project will be tagged using semantic versioning - `YYYY.MM.REVISION`.

All development should be done against the `develop` branch, `main` is deemed "stable".

## Requirements

* Cloudflare DNS for [ACME `DNS-01` authentication][dns-01-challenge] (Can be deliberately disabled to use [`HTTP-01` authentication][http-01-challenge] instead, or HTTPS can be disabled entirely if you plan to use an external termination point.)
* S3(Alike)/Azure for [Litestream][litestream-wob] (Can be deliberately disabled for full ephemerality, or if you plan to use persistent storage)

## Installation

Populate your environment variables according to `templates/secrets.template.env`

The container entrypoint script will guide you on any errors.

## Deployment and user creation

Once app is deployed and green, [generate an API Key][headscale-usage] in order to use the admin interface.

```console
headscale apikeys create
```

Navigate to the admin gui on `/admin/` and set up your groups, ACLs, tags etc.

## Final configuration

Now that Headscale is running, to have a 100% reproducible setup we need to ensure that private noise key generated during installation is persisted. Within the same console from previous step, print out the server's key:

```console
cat /data/noise_private.key
```

Then set `HEADSCALE_NOISE_PRIVATE_KEY` to the value obtained above.

Note that applying this will cause your application to restart, but afterwards no other change will be necessary.

## Known to run on

* Azure Container Apps
* [Fly.io][fly-io-instructions]
* ??? Let us know!

[alpine-linux-wob]: https://www.alpinelinux.org/
[alpine-linux-repo]: https://gitlab.alpinelinux.org/alpine
[caddy-wob]: https://caddyserver.com/
[caddy-repo]: https://github.com/caddyserver/caddy
[headscale-admin-wob]: https://github.com/GoodiesHQ/headscale-admin
[headscale-admin-repo]: [headscale-admin-wob]
[headscale-wob]: https://headscale.net/
[headscale-repo]: https://github.com/juanfont/headscale
[litestream-wob]: https://litestream.io/
[litestream-repo]: https://github.com/benbjohnson/litestream

[dns-01-challenge]: https://letsencrypt.org/docs/challenge-types/#dns-01-challenge
[http-01-challenge]: https://letsencrypt.org/docs/challenge-types/#http-01-challenge
[headscale-usage]: https://headscale.net/stable/ref/remote-cli/#create-an-api-key
[fly-io-instructions]: docs/backends/fly-io.md
