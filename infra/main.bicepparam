using './main.bicep'

param location = 'canadacentral'
param namePrefix = 'octo-health'
param tags = {
  purpose: 'health-model-training'
  environment: 'lab'
  owner: 'octo'
}
