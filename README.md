# Headscale on an immutable Docker image

Deploy [Headscale][headscale] using a "serverless" immutable docker image with real-time [Litestream][litestream] database backup and (by default) inbuilt [Caddy][caddy] SSL termination. Provides a stateless [headscale-admin](headscale-admin) panel at `/admin/`.

## Requirements

* Cloudflare DNS for [ACME `DNS-01` authentication](dns-01-challenge) (Can be deliberately disabled to use [`HTTP-01` authentication](http-01-challenge) instead)
* S3(Alike)/Azure for [Litestream][litestream] (Can be deliberately disabled for full ephemerality)

## Installation

Populate your environment variables according to `templates/secrets.template.env`

The container entrypoint script will guide you on any errors.

## Deployment and user creation

Once app is deployed and green, [generate an API Key](headscale-usage) in order to use the admin interface.

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
[dns-01-challenge]: https://letsencrypt.org/docs/challenge-types/#dns-01-challenge
[http-01-challenge]: https://letsencrypt.org/docs/challenge-types/#http-01-challenge
[headscale-usage]: https://headscale.net/stable/ref/remote-cli/#create-an-api-key
[caddy]: https://caddyserver.com/
