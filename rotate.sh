#!/usr/bin/env bash

export subscription=${AZURE_SUBSCRIPTION}
export resourceGroup=${AZURE_RESOURCE_GROUP}
export apimName=${AZURE_API_MANAGEMENT}
export gateway=${AZURE_APIM_GATEWAY}

export servicePrincipalUser=${AZURE_SP_USERNAME}
export servicePrincipalPass=${AZURE_SP_PASSWORD}
export tenant=${AZURE_TENANT}

# +%m gives a month so this if is always true ?
if [ "$(date +%d)" -le 15 ]
then
    keyType="secondary"
    rotatedKey="primary"
else
    keyType="primary"
    rotatedKey="secondary"
fi

echo "Log into Azure via Service Principal"
az login --service-principal --username "${servicePrincipalUser}" --password "${servicePrincipalPass}" --tenant "${tenant}" || (echo "az login failed with service principal '${servicePrincipalUser}'" && exit 1)

echo "Set Azure Subscription to ${subscription}"
az account set -s "${subscription}"
id=$(az account show -o tsv --query id)
uri="https://management.azure.com/subscriptions/${id}/resourceGroups/${resourceGroup}/providers/Microsoft.ApiManagement/service/${apimName}/gateways/${gateway}"

# expiry date set to 29 days after the current script is run
expiry=$(date -d @"$(date +"%s + $((3600*24*29))" | xargs expr)" +"%Y-%m-%dT%H:%m:00Z")
echo "Get Token set to expired on ${expiry} (today is $(date +"%Y-%m-%dT%H:%m:00Z"))"
token=$(az rest --method POST --uri "${uri}/generateToken/?api-version=2021-08-01" --body "{ \"expiry\": \"${expiry}\", \"keyType\": \"${keyType}\" }" | jq .value | tr -d "\"")

if [ -n "$token" ]
then
    echo "Update Secret in Kubernetes"
    kubectl delete secret "${gateway}-token"
    kubectl create secret generic "${gateway}-token" --from-literal=value="GatewayKey ${token}"  --type=Opaque

    echo "Rollout Deployment in Kubernetes"
    kubectl rollout restart deployment "${gateway}"

    # done for security reasons as it invalidates previous token, disruption risk if rollout fails ?
    echo "Rotate ${rotatedKey} Key"
    az rest --method POST --uri "${uri}/regenerateKey?api-version=2021-08-01" --body "{ \"keyType\": \"${rotatedKey}\" }"
else
    echo "Retrieved token is blank, stopping rotation there and leaving Kubernetes resources as is"
    exit 1
fi
