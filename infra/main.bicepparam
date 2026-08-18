using './main.bicep'

param location = 'eastus'
param namePrefix = 'octo-health'
param tags = {
  purpose: 'health-model-training'
  environment: 'lab'
  owner: 'octo'
}
