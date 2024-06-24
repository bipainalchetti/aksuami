targetScope='subscription'
param resourceGroupName string = 'hashbnuswest'
param resourceGroupLocation string = 'westus'

resource newRGwest 'Microsoft.Resources/resourceGroups@2022-09-01' = {
    name: resourceGroupName
    location: resourceGroupLocation
}
