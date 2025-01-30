# Headscale on an immutable Docker image

Deploy [Headscale][headscale] using a "serverless" immutable docker image with real-time [Litestream][litestream] database backup and (by default) inbuilt [Caddy][caddy] SSL termination

## Requirements

* Cloudflare DNS for [ACME `DNS-01` authentication](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge) (Can be deliberately disabled to use [`HTTP-01` authentication](https://letsencrypt.org/docs/challenge-types/#http-01-challenge) instead)
* S3(Alike)/Azure for [Litestream][litestream] (Can be deliberately disabled for full ephemerality)

## Installation

Either copy the template `templates/secrets.template.env` to `` and populate with appropriate values

```console
$ cp templates/secrets.template.env secrets.env
$ editor secrets.env
```

or use the template `templates/secrets.template.env` to set environment variables.

The container entrypoint will guide you on errors.

## Deployment and user creation

Once app is deployed and green, you can create your first user by using the console

Follow Headscale's [own documentation][headscale-usage] (steps 8 and registration of each machine or preauth keys), example:

```console
$ headscale users create homelab
```

## Final configuration

Now that Headscale is running, to have a 100% reproducible setup we need to ensure that private noise key generated during installation is persisted. Within the same console from previous step, print out the server's key:

```console
$ cat /data/noise_private.key
```

Then set `$HEADSCALE_NOISE_PRIVATE_KEY` to the value obtained above.

Note that applying this will cause your application to restart, but afterwards no other change will be necessary.

[headscale]: https://github.com/juanfont/headscale
[litestream]: https://litestream.io/
[headscale-usage]: https://github.com/juanfont/headscale/blob/main/docs/running-headscale-linux.md#configure-and-run-headscale
[caddy]: https://caddyserver.com/
