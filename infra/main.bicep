targetScope = 'resourceGroup'

@description('Azure region for the sample workload.')
param location string = resourceGroup().location

@description('Short prefix used for resource names.')
@minLength(2)
@maxLength(20)
param namePrefix string = 'octo-health'

@description('Tags applied to the sample resources.')
param tags object = {
  purpose: 'health-model-training'
  environment: 'lab'
}

var suffix = uniqueString(subscription().subscriptionId, resourceGroup().id)
var workspaceName = '${namePrefix}-logs-${suffix}'
var environmentName = '${namePrefix}-env-${suffix}'
var appName = '${namePrefix}-app-${suffix}'

module workspace 'br/public:avm/res/operational-insights/workspace:0.16.0' = {
  params: {
    name: workspaceName
    location: location
    dataRetention: 30
    tags: tags
  }
}

module environment 'br/public:avm/res/app/managed-environment:0.15.0' = {
  params: {
    name: environmentName
    location: location
    publicNetworkAccess: 'Enabled'
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsWorkspaceResourceId: workspace.outputs.resourceId
    }
    tags: tags
  }
}

module app 'br/public:avm/res/app/container-app:0.23.0' = {
  params: {
    name: appName
    location: location
    environmentResourceId: environment.outputs.resourceId
    containers: [
      {
        name: 'hello'
        image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        resources: {
          cpu: json('0.25')
          memory: '0.5Gi'
        }
      }
    ]
    ingressExternal: true
    ingressAllowInsecure: false
    ingressTargetPort: 80
    scaleSettings: {
      minReplicas: 1
      maxReplicas: 2
    }
    tags: tags
  }
}

output appUrl string = 'https://${app.outputs.fqdn}'
output containerAppResourceId string = app.outputs.resourceId
output environmentResourceId string = environment.outputs.resourceId
output logAnalyticsWorkspaceResourceId string = workspace.outputs.resourceId
