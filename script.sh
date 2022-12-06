#! /bin/bash

export RG_NAME="default"
export LOCATION="eastus"

export CUSTOM_DOMAIN_NAME="example.com"
export SUBDOMAIN="test.$CUSTOM_DOMAIN_NAME" 

#######################################################
## Loginto Azure-CLI
# Ensure you're logged out of existing Azure Account
az logout

# Login with new account
az login -u $ADMIN_EMAIL -p $ADMIN_PASSWORD

#######################################################
## Get Sub Info
echo "Getting az account info..."
export ACCOUNT_INFO=$(az account show -o json)
echo $ACCOUNT_INFO

export TENANT_ID=$(echo $ACCOUNT_INFO | jq -r .tenantId)
echo "TENANT_ID: $TENANT_ID"

export AZURE_SUB_ID=$(echo $ACCOUNT_INFO | jq -r .id)
echo "AZURE_SUB_ID: $AZURE_SUB_ID"

#######################################################
## Create default resource group
az group create -n $RG_NAME -l $LOCATION

#######################################################
## Create Public DNS Zone and save output to variable
export DOMAIN_INFO=$(az network dns zone create -n $SUBDOMAIN -p $CUSTOM_DOMAIN_NAME -g $RG_NAME -o json)

az network private-dns zone create -g externaldns -n example.com

az network private-dns link vnet create -g $RG_NAME -n testlink -z $SUBDOMAIN -v $VNET_ID --registration-enabled false

# Update Domain NS Servers with Domain Registrar
echo $DOMAIN_INFO | jq -r .nameServers

export CLUSTER_INFO=$(az aks list -o json | jq -r .[0])
export CLUSTER_NAME=$(echo $CLUSTER_INFO | jq -r '.name')
export CLUSTER_RG=$(echo $CLUSTER_INFO | jq -r '.resourceGroup')

export AZ_DNS_SCOPE=$(echo $DOMAIN_INFO | jq -r .id)

export CLUSTER_MSI=$( az aks show -g $CLUSTER_RG -n $CLUSTER_NAME --query "identity" | jq -r .principalId)

export KUBELET_MSI=$(az aks show -g $CLUSTER_RG -n $CLUSTER_NAME --query "identityProfile.kubeletidentity.objectId" --output tsv)


az role assignment create \
  --assignee $KUBELET_MSI \
  --role "DNS Zone Contributor" \
  --scope "$AZ_DNS_SCOPE"

az role assignment create \
  --assignee $KUBELET_MSI \
  --role "Contributor" \
  --scope "/subscriptions/$AZURE_SUB_ID/resourceGroups/$RG_NAME"

az role assignment create \
  --assignee $CLUSTER_MSI \
  --role "Contributor" \
  --scope "/subscriptions/$AZURE_SUB_ID/resourceGroups/$RG_NAME"

az role assignment list --assignee $KUBELET_MSI --all \
  --query '[].{roleDefinitionName:roleDefinitionName, provider:scope}' \
  --output table | sed 's|/subscriptions.*providers/||' | cut -c -80

az role assignment list --assignee $CLUSTER_MSI --all \
  --query '[].{roleDefinitionName:roleDefinitionName, provider:scope}' \
  --output table | sed 's|/subscriptions.*providers/||' | cut -c -80

helmfile apply

export LABEL_NAME="app.kubernetes.io/name=external-dns"
export LABEL_INSTANCE="app.kubernetes.io/instance=external-dns"

export EXTERNAL_DNS_POD_NAME=$(kubectl --namespace kube-addons get pods --selector "$LABEL_NAME,$LABEL_INSTANCE" --output name)

kubectl logs --namespace kube-addons $EXTERNAL_DNS_POD_NAME

# Setup Auto TLS with ingress/certmanager


helm repo add jetstack https://charts.jetstack.io
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update


# kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.10.1/cert-manager.yaml

helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.10.1 # --set installCRDs=true
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.10.1/cert-manager.crds.yaml
helm install ingress-nginx ingress-nginx/ingress-nginx --set controller.publishService.enabled=true
