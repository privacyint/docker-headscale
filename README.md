# Headscale on an immutable Docker image

It should be easier to deploy [Headscale][headscale] without having to touch
configuration files.

This repository aims to provide that while still providing a good backup
strategy and ensuring your Headscale configuration is persisted, using
[Litestream][litestream]

## Requirements

* Azure Account
* An existing Azure BLOB (hot) storage for backups
* A domain name to use

## Installation

### 1. Create your Headscale application

We need to create a volume in Azure that will be used to store Headscale's
configuration and database. This needs to be connected to the application
created before.

### 2. Setting up a domain and IP address for a SSL certificate

### 3. Setting up the configuration

With the domain name and the BLOB configuration, you can copy the template
`templates/secrets.template.env` and enter the appropriate values:

```console
$ cp templates/secrets.template.env secrets.env
```

Make sure you update `HEADSCALE_SERVER_URL` and `HEADSCALE_BASE_DOMAIN` to
point to the Headscale server URL and the domain you want to use.

Do not forget to include the scheme (`https`) **and** the port (`443`) in the
server URL. Example:

```
HEADSCALE_SERVER_URL=https://hs.example.com:443/
HEADSCALE_BASE_DOMAIN=example.com
```

Now, you need to enter your Azure credentials and endpoint, necessary
for Litestream to work correctly.

Note that this setup **requires** Azure BLOB storage and will not work without it.
(Also, is not recommended deploy something without a proper backup strategy).

### 4. Deployment and user creation

With all the settings in place, we are ready to deploy the application

Once app is deployed and green, you can create your first user by using the
console

Follow Headscale's [own documentation][headscale-usage] (steps 8 and
registration of each machine or preauth keys), example:

```console
$ headscale users create homelab
```

### 5. Final configuration

Now that Headscale is running, to have a 100% reproducible setup, we need to
ensure that private keys initialized by our installation are persisted, so
we need to capture the contents of `/data/private.key` and
`/data/noise_private.key` and place into secrets of our application.

Within the same console from previous step, obtain the contents of these
files:

```console
$ cat /data/private.key

$ cat /data/noise_private.key
```

Copy those to your clipboard and terminate the console.

Locally, set `HEADSCALE_PRIVATE_KEY` and 
`HEADSCALE_NOISE_PRIVATE_KEY` with the values obtained before, respectively

Note that applying these two variables will cause your application to restart,
but afterwards no other change will be necessary.

[headscale]: https://github.com/juanfont/headscale
[litestream]: https://litestream.io/
[headscale-usage]: https://github.com/juanfont/headscale/blob/main/docs/running-headscale-linux.md#configure-and-run-headscale
