# Deploying to Azure Container Apps

This guide walks through deploying a `docker-headscale` meshnet to Microsoft Azure using Azure Container Apps.

Anything starting with a `$` is a placeholder value that must be replaced with a real value from your environment.

This guide assumes Azure Container Apps will terminate HTTPS for you. The container therefore runs with `CADDY_FRONTEND=DISABLE_HTTPS` and listens on plain HTTP internally.

The repo includes a reusable Azure Container Apps YAML template at `templates/azure-container-apps.template.yaml` so you do not need to hand-edit an exported app definition.

## Table of Contents

- [Assumptions](#assumptions)
- [Step 0: Pull the latest code version](#step-0-pull-the-latest-code-version)
- [Step 1: Initialise Azure CLI](#step-1-initialise-azure-cli)
- [Step 2: Create your Azure resources](#step-2-create-your-azure-resources)
- [Step 3: Deploy the container app](#step-3-deploy-the-container-app)
- [Step 4: Mount persistent storage at `/data`](#step-4-mount-persistent-storage-at-data)
- [Step 5: Add your custom domain and HTTPS](#step-5-add-your-custom-domain-and-https)
- [Step 6: Optionally enable Litestream backup to Azure Blob Storage](#step-6-optionally-enable-litestream-backup-to-azure-blob-storage)
- [Step 7: Monitor your application](#step-7-monitor-your-application)
- [Step 8: Finalise Headscale after first deployment](#step-8-finalise-headscale-after-first-deployment)
- [Conclusion](#conclusion)

## Assumptions

This document assumes the following:

- You have an Azure subscription
- You have the Azure CLI installed locally
- You control the DNS records of a domain
- You have a Git client installed
- You are happy to run a single replica of Headscale

## Step 0: Pull the latest code version

Pull the latest code and switch to the project directory.

```sh
git clone https://github.com/privacyint/docker-headscale.git
cd docker-headscale
git checkout main
```

## Step 1: Initialise Azure CLI

Log in, make sure the Container Apps tooling is available, and define the values used throughout the rest of this guide.

`$publicServerURL` should be the final public hostname you want clients to use, for example `headscale.example.org`.

`$tailnetInternalDomain` should be the MagicDNS base domain you want Headscale to hand to clients, for example `tailnet.example.internal`.

```sh
az login
az extension add -n containerapp --upgrade
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights

export RESOURCE_GROUP=$resourceGroup
export LOCATION=$azureRegion
export CONTAINER_APP_ENV=$containerAppEnvironment
export CONTAINER_APP_NAME=$containerAppName
export STORAGE_ACCOUNT_NAME=$storageAccountName
export STORAGE_SHARE_NAME=hs-data
export STORAGE_MOUNT_NAME=hsdata
export PUBLIC_SERVER_URL=$publicServerURL
export HEADSCALE_DNS_BASE_DOMAIN=$tailnetInternalDomain
```

## Step 2: Create your Azure resources

Create a resource group, a Container Apps environment, and an Azure Files share for `/data`.

The `/data` mount is important because this image stores the SQLite database, Caddy state, and Headscale Noise private key there.

```sh
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

az containerapp env create \
  --name $CONTAINER_APP_ENV \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

export CONTAINER_APP_ENVIRONMENT_ID=$(az containerapp env show \
  --name $CONTAINER_APP_ENV \
  --resource-group $RESOURCE_GROUP \
  --query id \
  --output tsv)

az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT_NAME \
  --location $LOCATION \
  --kind StorageV2 \
  --sku Standard_LRS \
  --enable-large-file-share

az storage share-rm create \
  --resource-group $RESOURCE_GROUP \
  --storage-account $STORAGE_ACCOUNT_NAME \
  --name $STORAGE_SHARE_NAME \
  --quota 1024 \
  --enabled-protocols SMB

export STORAGE_ACCOUNT_KEY=$(az storage account keys list \
  --resource-group $RESOURCE_GROUP \
  --account-name $STORAGE_ACCOUNT_NAME \
  --query '[0].value' \
  --output tsv)

az containerapp env storage set \
  --name $CONTAINER_APP_ENV \
  --resource-group $RESOURCE_GROUP \
  --storage-name $STORAGE_MOUNT_NAME \
  --access-mode ReadWrite \
  --azure-file-account-name $STORAGE_ACCOUNT_NAME \
  --azure-file-account-key "$STORAGE_ACCOUNT_KEY" \
  --azure-file-share-name $STORAGE_SHARE_NAME
```

## Step 3: Deploy the container app

Deploy the app directly from the checked out source tree.

This command builds the local `Dockerfile`, pushes the image to Azure-managed registry infrastructure, and creates the Container App.

`LITESTREAM_REPLICA_URL` is deliberately disabled at first because persistent Azure Files storage is already mounted in the next step.

```sh
az containerapp up \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINER_APP_ENV \
  --location $LOCATION \
  --source . \
  --ingress external \
  --target-port 8008 \
  --env-vars \
    PUBLIC_SERVER_URL=$PUBLIC_SERVER_URL \
    HEADSCALE_DNS_BASE_DOMAIN=$HEADSCALE_DNS_BASE_DOMAIN \
    CADDY_FRONTEND=DISABLE_HTTPS \
    LITESTREAM_REPLICA_URL=DISABLED_I_KNOW_WHAT_IM_DOING
```

Do not enrol clients yet. We still need to attach the persistent volume so the database and Noise key survive restarts.

## Step 4: Mount persistent storage at `/data`

Render the bundled Azure Container Apps YAML template, then apply it back to the app.

```sh
export CONTAINER_IMAGE=$(az containerapp show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.template.containers[0].image' \
  --output tsv)

envsubst < templates/azure-container-apps.template.yaml > azure-container-apps.yaml
```

The generated file already includes the required `/data` mount, single-replica scale settings, and the repo's required environment variables.

The relevant parts should look like this:

```yaml
identity:
  type: SystemAssigned
properties:
  configuration:
    ingress:
      external: true
      targetPort: 8008
  template:
    containers:
      - image: <existing image value>
        env:
          - name: CADDY_FRONTEND
            value: DISABLE_HTTPS
        volumeMounts:
          - volumeName: hs-data
            mountPath: /data
    volumes:
      - name: hs-data
        storageName: hsdata
        storageType: AzureFile
```

Apply the updated definition:

```sh
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --yaml azure-container-apps.yaml
```

## Step 5: Add your custom domain and HTTPS

Azure Container Apps can issue and renew a managed certificate for you. Because HTTPS is terminated by Azure, the container should continue using `CADDY_FRONTEND=DISABLE_HTTPS`.

First, fetch the generated Container Apps hostname and the domain verification ID:

```sh
az containerapp show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query properties.configuration.ingress.fqdn \
  --output tsv

az containerapp show-custom-domain-verification-id
```

Then create the required DNS records:

- For a subdomain such as `headscale.example.org`, create a `CNAME` from `headscale` to the generated Container Apps hostname
- Create the matching `TXT` record for Azure's ownership check, typically `asuid.headscale`
- If you use `CAA` records, make sure `digicert.com` is allowed or certificate issuance will fail

After DNS has propagated, go to your Container App in the Azure portal:

1. Open `Networking`.
2. Open `Custom domains`.
3. Add your hostname.
4. Choose `Managed certificate`.
5. Complete validation and wait for the status to become `Secured`.

## Step 6: Optionally enable Litestream backup to Azure Blob Storage

The basic deployment above is already persistent because `/data` is backed by Azure Files. If you also want off-instance backup, you can configure Litestream to replicate the SQLite database to Azure Blob Storage.

Create a blob container:

```sh
export BLOB_CONTAINER_NAME=$blobContainerName

az storage container create \
  --account-name $STORAGE_ACCOUNT_NAME \
  --name $BLOB_CONTAINER_NAME \
  --account-key "$STORAGE_ACCOUNT_KEY"
```

You now have two supported authentication choices for Litestream.

### Option A: shared key authentication

Set the storage account key as a Container Apps secret:

```sh
az containerapp secret set \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --secrets litestream-azure-account-key="$STORAGE_ACCOUNT_KEY"
```

Then update the app configuration:

```sh
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --set-env-vars \
    LITESTREAM_REPLICA_URL=abs://$STORAGE_ACCOUNT_NAME@$BLOB_CONTAINER_NAME/headscale/headscale.sqlite3 \
    LITESTREAM_AZURE_ACCOUNT_KEY=secretref:litestream-azure-account-key
```

### Option B: managed identity authentication

This repo now allows `abs://` replication without `LITESTREAM_AZURE_ACCOUNT_KEY`, so you can use the Container App's managed identity instead.

First, fetch the managed identity principal ID:

```sh
export CONTAINER_APP_PRINCIPAL_ID=$(az containerapp show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query identity.principalId \
  --output tsv)
```

Grant that identity the least privilege it needs on the blob container:

```sh
export SUBSCRIPTION_ID=$(az account show --query id --output tsv)

az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id $CONTAINER_APP_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME/blobServices/default/containers/$BLOB_CONTAINER_NAME
```

Then configure Litestream without a storage account key:

```sh
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --remove-env-vars LITESTREAM_AZURE_ACCOUNT_KEY \
  --set-env-vars \
    LITESTREAM_REPLICA_URL=abs://$STORAGE_ACCOUNT_NAME@$BLOB_CONTAINER_NAME/headscale/headscale.sqlite3
```

Role assignment propagation is not immediate. If Litestream logs permission errors straight away, wait a few minutes and try again.

## Step 7: Monitor your application

You can monitor the app through the Azure portal or with the CLI:

```sh
az containerapp show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --output table

az containerapp logs show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --follow
```

## Step 8: Finalise Headscale after first deployment

Once the app is healthy and the custom domain is in place, open a shell inside the container:

```sh
az containerapp exec \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP
```

From there, create an API key for the admin UI:

```sh
headscale apikeys create
```

Then print the generated Noise private key:

```sh
cat /data/noise_private.key
```

Store that value back in Azure as an environment variable called `HEADSCALE_NOISE_PRIVATE_KEY`. This makes future deployments reproducible and avoids forcing all clients to re-authenticate when the container is replaced.

Afterwards, the admin interface will be available at `/admin/` on your public URL.

## Conclusion

You have successfully deployed your application to Azure Container Apps with persistent storage. For a simpler setup, stop after Step 5 and rely on Azure Files alone. For a more resilient setup, also complete Step 6 so Litestream replicates the SQLite database to Azure Blob Storage.
