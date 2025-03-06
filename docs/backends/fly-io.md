# Deploying to Fly.io

This guide will walk you through the steps to deploy a `docker-headscale` meshnet on Fly.io.

## Assumptions

The assumptions made in this document are the following:

- You have a Fly.io account
- You have Fly CLI installed
- You control the DNS records of a domain
- You have a Git client installed

## Step 0: Pull the latest code version

Pull the latest tag from PI's `master` branch, and switch to the directory.

## Step 1: Initialize Fly.io

Log into Fly.io and create a new application.

`<your-app-name>` may be anything, but must be unique to Fly.io.

```sh
flyctl auth login
flyctl apps create <your-app-name>
```

## Step 2: Create persistent storage

`<your-app-region>` may be any Fly.io region. n.b. [How to find valid Fly regions](https://fly.io/docs/flyctl/platform-regions/)

You can also use a randomly generated `app` name by using `--generate-name` in place of `--app <your-app-name>`

```sh
flyctl volumes create --app <your-app-name> --region <your-app-region> --size 1 hs_data
```

## Step 3: Allocate IP addresses

```sh
flyctl ips allocate-v4 --shared
flyctl ips allocate-v6
```

Add the above generated IP addresses to the required `A` and `AAAA` records.

## Step 4: Deploy an `HTTPS` certificate using Fly's CLI

```sh
flyctl certs add <public-DNS-address>
```

## Step 5: Customise your configuration

Create a customised `fly.toml` configuration file in the root of your project from the template:

```sh
FLY_APP=<your-app-name> PUBLIC_SERVER_URL=<public-DNS-address> HEADSCALE_DNS_CONFIG_BASE_DOMAIN=<tailnet-internal-domain> envsubst < templates/fly.template.toml > fly.toml
```

## Step 6: Deploy Your Application

Deploy your application using the Fly CLI:

```sh
flyctl deploy
```

## Step 7: Monitor Your Application

You can monitor your application using the Fly.io dashboard or the Fly CLI:

```sh
flyctl status
```

## Conclusion

You have successfully deployed your application to Fly.io. For more information, refer to the [Fly.io documentation](https://fly.io/docs/).
