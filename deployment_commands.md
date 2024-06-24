# Bicep Deployment Commands

## Deploy Bicep file to create RG
az deployment sub create --location "westus" --template-file "rg.bicep"

## Deploy Bicep file to create AKS Cluster using spotnodepool
az deployment group create --resource-group hashbn --template-file aks_spotnodepool.bicep

## Deploy Bicep file to create AKV
az deployment group create --resource-group hashbn --template-file akv.bicep

## Provide AKV read secrets access to the UAMI
az role assignment create --assignee-object-id "${IDENTITY_PRINCIPAL_ID}" --role "Key Vault Secrets User" --scope "${KEYVAULT_RESOURCE_ID}" --assignee-principal-type ServicePrincipal

