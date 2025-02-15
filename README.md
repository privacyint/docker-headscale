# Headscale on an immutable Docker image

Deploy [Headscale][headscale] using a "serverless" immutable docker image with real-time [Litestream][litestream] database backup and (by default) inbuilt [Caddy][caddy] SSL termination, using a miniscule [Alpine Linux][alpine-linux] base image. Provides a stateless [headscale-admin][headscale-admin] panel at `/admin/`.

## Included upstream versions

| Tool | Version |
|---|---|
| [`Alpine Linux`](alpine-linux) | [`v3.21.2`](https://git.alpinelinux.org/aports/log/?h=v3.21.2)
| [`Headscale`](headscale) | [`v0.25.0`](https://github.com/juanfont/headscale/releases/tag/v0.25.0) |
| [`Headscale-Admin`](headscale-admin) | [`v.0.24.9`](https://github.com/GoodiesHQ/headscale-admin/releases/tag/v0.24.9) |
| [`Litestream`](litestream) | [`v0.3.13`](https://github.com/benbjohnson/litestream/releases/tag/v0.3.13) |
| [`Caddy`](caddy) | [`v2.9.1`](https://github.com/caddyserver/caddy/releases/tag/v2.9.1) |


## Versioning

Because of the mix of upstream tools included, this project will be tagged using semantic versioning - `YYYY.MM.REVISION`.

All development should be done against the `develop` branch, `main` is deemed "stable".

## Requirements

* Cloudflare DNS for [ACME `DNS-01` authentication][dns-01-challenge] (Can be deliberately disabled to use [`HTTP-01` authentication][http-01-challenge] instead)
* S3(Alike)/Azure for [Litestream][litestream] (Can be deliberately disabled for full ephemerality)

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

[headscale]: https://github.com/juanfont/headscale
[litestream]: https://litestream.io/
[headscale-admin]: https://github.com/GoodiesHQ/headscale-admin
[alpine-linux]: https://www.alpinelinux.org/
[dns-01-challenge]: https://letsencrypt.org/docs/challenge-types/#dns-01-challenge
[http-01-challenge]: https://letsencrypt.org/docs/challenge-types/#http-01-challenge
[headscale-usage]: https://headscale.net/stable/ref/remote-cli/#create-an-api-key
[caddy]: https://caddyserver.com/
