# Deploying to Fly.io

This guide will walk you through the steps to deploy a `docker-headscale` meshnet on Fly.io.

Anything starting with a `$` is a placeholder value which will need to be replaced with real values from the commands.

## Table of Contents

- [Assumptions](#assumptions)
- [Prerequisites](#prerequisites)
- [Step 0: Pull the latest code version](#step-0-pull-the-latest-code-version)
- [Step 1: Initialize Fly.io](#step-1-initialize-flyio)
- [Step 2: Create persistent storage](#step-2-create-persistent-storage)
- [Step 3: Allocate IP addresses](#step-3-allocate-ip-addresses)
- [Step 4: Deploy an HTTPS certificate using Fly's CLI](#step-4-deploy-an-https-certificate-using-flys-cli)
- [Step 5: Customise your configuration](#step-5-customise-your-configuration)
- [Step 6: Deploy Your Application](#step-6-deploy-your-application)
- [Step 7: Monitor Your Application](#step-7-monitor-your-application)
- [Conclusion](#conclusion)

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

`$yourAppName` may be anything, but must be unique to Fly.io.

```sh
flyctl auth login
flyctl apps create $yourAppName
```

## Step 2: Create persistent storage

`$yourAppRegion` may be any Fly.io region. n.b. [How to find valid Fly regions](https://fly.io/docs/flyctl/platform-regions/)

You can also use a randomly generated app name by using `--generate-name` in place of `--app $yourAppName`

```sh
flyctl volumes create --app $yourAppName --region $yourAppRegion --size 1 hs_data
```

## Step 3: Allocate IP addresses

```sh
flyctl ips allocate-v4 --shared
flyctl ips allocate-v6
```

Add the above generated IP addresses to the required `A` and `AAAA` records.

## Step 4: Deploy an `HTTPS` certificate using Fly's CLI

```sh
flyctl certs add $publicServerURL
```

## Step 5: Customise your configuration

Create a customised `fly.toml` configuration file in the root of your project from the template:

```sh
export FLY_APP=$yourAppName
export PUBLIC_SERVER_URL=$publicServerURL
export HEADSCALE_DNS_CONFIG_BASE_DOMAIN=$tailnetInternalDomain
envsubst < templates/fly.template.toml > fly.toml
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
