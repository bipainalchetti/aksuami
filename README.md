### Use Case:

* We have a token/secret stored in an Azure Key Vault secret
    
* We have a pod in a Cluster that needs to read this secret.
    
* We will use UAMI to enable the pod to read the secret stored in the AKV
    

![](https://cdn.hashnode.com/res/hashnode/image/upload/v1717838205963/e5b142a2-1f60-414d-9e76-d2a3ab047d6e.png align="center")

### Let's decode this in simple terms:

**Pre-requisites:** \--&gt; AKS cluster & Azure Cli 2.47.0 or greater

1. **Lets enable the Workload Identity on the AKS Cluster**
    
    ```bash
    # Define RG & ClusterName
    export RESOURCE_GROUP="hashbnuswest"
    export CLUSTER_NAME="hashbnuswest"
    
    az aks update --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" --enable-oidc-issuer \
    --enable-workload-identity
    ```
    
2. **Why do we need Workload Identity ?**
    
    * As humans, we use our Azure credentials to access the AKV from the Azure portal.
        
    * As an application we use Service Principals to login to Azure and access the AKV contents provided access read/write .... access has been provided to the vault.
        
    * How does the pod authenticate itself, as it does not have an identity of its own as it resides inside the AKS Cluster, so let's use the native Kubernetes concept of ServiceAccount and connect it with UAMI in Azure.
        
3. **Registering the Identity in Azure**
    
    * Lets create a UserAssignedManagedIdentity (UAMI) in Azure
        
    * We create a Kubernetes Serviceaccount (SA) for the namespace in which the pod resides and reference the clientID of the UAMI.
        
        ```bash
              # We need an UAMI resource to be created in Azure
              # which will be mapped to the service account in K8s
              export UAMI_NAME="UAMI_WL_IDENTITY"
            
              az identity create --resource-group $RESOURCE_GROUP \
              --name $UAMI_NAME
              
              #Retrieve the clientID from the output or using below command
              export USER_ASSIGNED_CLIENT_ID="$(az identity show \
              --resource-group "${RESOURCE_GROUP}" \
              --name "${USER_ASSIGNED_IDENTITY_NAME}" \
              --query 'clientId' --output tsv)"
              
              #Lets create the namespace in AKS
              export SERVICE_ACCOUNT_NAMESPACE="wlipoc"
              kubectl create ns $SERVICE_ACCOUNT_NAMESPACE
              
              # Lets create the ServiceAccount mapping it to ClientId of UAMI
              export SERVICE_ACCOUNT_NAME="workload-identity-sa"
              
              cat <<EOF | kubectl apply -f -
              apiVersion: v1
              kind: ServiceAccount
              metadata:
                annotations:
                  azure.workload.identity/client-id: "${USER_ASSIGNED_CLIENT_ID}"
                name: "${SERVICE_ACCOUNT_NAME}"
                namespace: "${SERVICE_ACCOUNT_NAMESPACE}"
              EOF
              
              # Output:
              serviceaccount/workload-identity-sa created
        ```
        
4. Create Federated Credentials to authenticate your workloads against IDP:
    
    * [How do Federated Credentials work](https://learn.microsoft.com/en-us/graph/api/resources/federatedidentitycredentials-overview?view=graph-rest-1.0#how-do-federated-identity-credentials-work)
        
        ```bash
          # Lets fetch the OIDC URL
          export AKS_OIDC_ISSUER="$(az aks show --name "${CLUSTER_NAME}" \
          --resource-group "${RESOURCE_GROUP}" \
          --query "oidcIssuerProfile.issuerUrl" --output tsv)"
          
          # Lets create the federated credential
          export FEDERATED_IDENTITY_CREDENTIAL_NAME=wlipoc
          
          az identity federated-credential create \
          --name ${FEDERATED_IDENTITY_CREDENTIAL_NAME} \
          --identity-name "${UAMI_NAME}" \
          --resource-group "${RESOURCE_GROUP}" \
          --issuer "${AKS_OIDC_ISSUER}" \
          --subject system:serviceaccount:"${SERVICE_ACCOUNT_NAMESPACE}":"${SERVICE_ACCOUNT_NAME}" \
          --audience api://AzureADTokenExchange
        ```
        
5. Lets deploy the container using workload identity & verify WLI is enabled correctly
    
    ```bash
    cat <<EOF | kubectl apply -f -
    apiVersion: v1
    kind: Pod
    metadata:
      name: wlipoc-pod
      namespace: wlipoc
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: workload-identity-sa
      containers:
      - name: alpine-container
        image: alpine
        command: ["/bin/sh", "-c", "--"]
        args: ["while true; do sleep 30; done;"]
    EOF
    
    # Verify if we have the below variables set inside the container
    kubectl exec -it wlipoc-pod -n wlipoc -- sh
    / # env | grep -i Azure
    AZURE_AUTHORITY_HOST=https://login.microsoftonline.com/
    AZURE_CLIENT_ID=a5ed94d2-2380-40f3-882c-0a4f85d9ed18
    AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token
    AZURE_TENANT_ID=2d8864a5-52db-4274-8d18-856d8d5caaf9
    / #
    ```
    
6. Lets now create an AKV with a secret using bicep --&gt; akv.bicep
    
    * ![](https://cdn.hashnode.com/res/hashnode/image/upload/v1719255370849/f466a586-8094-4b7d-860e-0b689aed7bbb.png align="center")
        
7. We have a UAMi which acts an identity for the pods in the namespace, so we have to give UAMI read secrets access to the AKV
    
    ```bash
    #Fetching the principalID for the UAMI
    export IDENTITY_PRINCIPAL_ID=$(az identity show --name \
    "${UAMI_NAME}" --resource-group \
    "${RESOURCE_GROUP}" --query principalId --output tsv)
    
    # Azure Key Vault Name
    export KEYVAULT_NAME="wliakvpoc"
    
    # Fetching the resourceID for AKV
    export KEYVAULT_RESOURCE_ID=$(az keyvault show --resource-group \
    "${RESOURCE_GROUP}" \
        --name "${KEYVAULT_NAME}" \
        --query id \
        --output tsv)
    
    # Assigning the Key Vault Secrets User to UAMI to read the secrets
    az role assignment create --assignee-object-id \
    "${IDENTITY_PRINCIPAL_ID}" --role "Key Vault Secrets User" \
    --scope "${KEYVAULT_RESOURCE_ID}" \
    --assignee-principal-type ServicePrincipal
    ```
    
8. Lets deploy a sample container which has code to read the secrets from the AKV
    
    * ```bash
        # AKV URL would be needed by the container to access the AKV
        export KEYVAULT_URL="$(az keyvault show \
        --resource-group ${RESOURCE_GROUP} \
        --name ${KEYVAULT_NAME} --query properties.vaultUri --output tsv)"
        
        # Defining the secret-name which we had created using the bicep file
        export KEYVAULT_SECRET_NAME=my-secret
        
        # Sample Container yaml using the image which would be able to connect
        # to AKV and read the secret
         
        cat <<EOF | kubectl apply -f -
        apiVersion: v1
        kind: Pod
        metadata:
          name: sample-workload-identity-key-vault
          namespace: ${SERVICE_ACCOUNT_NAMESPACE}
          labels:
            azure.workload.identity/use: "true"
        spec:
          serviceAccountName: ${SERVICE_ACCOUNT_NAME}
          containers:
            - image: ghcr.io/azure/azure-workload-identity/msal-go
              name: oidc
              env:
              - name: KEYVAULT_URL
                value: ${KEYVAULT_URL}
              - name: SECRET_NAME
                value: ${KEYVAULT_SECRET_NAME}
          nodeSelector:
            kubernetes.io/os: linux
        EOF
        ```
        
9. Lets verify whether the container is able to fetch the secrets
    
    ```bash
    kubectl get pods -n wlipoc
    
    NAME                                 READY   STATUS    RESTARTS   AGE
    sample-workload-identity-key-vault   1/1     Running   0          7s
    wlipoc-pod                           1/1     Running   0          117m
    ```
    
    ```bash
    kubectl describe pod sample-workload-identity-key-vault -n wlipoc \
    | grep "SECRET_NAME:"
    SECRET_NAME:                 my-secret
    ```
    
    ```bash
    kubectl logs sample-workload-identity-key-vault -n wlipoc
    I0622 15:24:34.752062       1 main.go:63] "successfully got secret" secret="hellowwss"
    I0622 15:25:34.824601       1 main.go:63] "successfully got secret" secret="hellowwss"
    ```
    

### References:

\- [Microsoft Learn | workload-identity-overview](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview?tabs=python)

\- [Deploy and configure an AKS cluster with workload identity - Azure Kubernetes Service | Microsoft Learn](https://learn.microsoft.com/en-us/azure/aks/workload-identity-deploy-cluster)
