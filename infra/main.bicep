targetScope = 'subscription'

@minLength(3)
@maxLength(30)
param environmentName string
param location string

var suffix = uniqueString(subscription().id, environmentName, location)

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: {
    'azd-env-name': environmentName
    application: 'azd-m365-demo-loader'
  }
}

module foundation 'modules/foundation.bicep' = {
  name: 'foundation'
  scope: group
  params: {
    location: location
    suffix: suffix
  }
}

output AZURE_RESOURCE_GROUP string = group.name
output AZURE_TENANT_ID string = subscription().tenantId
output AZURE_KEY_VAULT_NAME string = foundation.outputs.vaultName
output AZURE_KEY_VAULT_ENDPOINT string = foundation.outputs.vaultUrl
output AZURE_IDENTITY_RESOURCE_ID string = foundation.outputs.identityId
output AZURE_IDENTITY_CLIENT_ID string = foundation.outputs.identityClientId
output AZURE_IDENTITY_PRINCIPAL_ID string = foundation.outputs.identityPrincipalId
output AZURE_STORAGE_ACCOUNT_NAME string = foundation.outputs.storageName
output JOURNAL_BLOB_URL string = foundation.outputs.blobUrl
output ACI_NAME string = 'aci-${suffix}'
output ACI_DNS_LABEL string = 'm365-${suffix}'
output AZURE_LOG_WORKSPACE_NAME string = foundation.outputs.logWorkspaceName
output AZURE_CERT_STORAGE_NAME string = foundation.outputs.certificateStorageName
