targetScope = 'resourceGroup'

param location string = resourceGroup().location
param containerGroupName string
param dnsLabel string
param publicHostname string = ''
param acmeEmail string
param image string = loadJsonContent('../config/container-images.json').services.app.image
param caddyImage string = loadJsonContent('../config/container-images.json').services.caddy.image
param useManagedIdentityForImagePull bool = false
param identityResourceId string
param identityClientId string
param webClientId string = ''
param bootstrap bool = false
param tenantId string = tenant().tenantId
param operatorIds string
param authorizedGroupId string = ''
param deliveryEnabled bool = false
param mailboxScopeConfirmed bool = false
param allowExternalRecipients bool = false
param logWorkspaceName string

var bootstrapCaddyConfig = '''
:80 {
  respond "Deployment initialization in progress" 503
}
'''
var caddyConfig = bootstrap ? bootstrapCaddyConfig : loadTextContent('../Caddyfile')
var registryServers = union([split(image, '/')[0]], [split(caddyImage, '/')[0]])
var registryCredentials = [
  for server in registryServers: {
    server: server
    identity: identityResourceId
  }
]
var applicationStartup = bootstrap
  ? {
      command: ['python', '-c', 'import time; time.sleep(2147483647)']
    }
  : {
      // Explicitly reset the dormant bootstrap command when updating the same group.
      command: [
        'uvicorn'
        'demo_loader.app:create_app'
        '--factory'
        '--host'
        '0.0.0.0'
        '--port'
        '8000'
        '--workers'
        '1'
        '--no-proxy-headers'
        '--no-access-log'
      ]
      readinessProbe: {
        exec: {
          command: [
            'python'
            '-c'
            'import urllib.request; r=urllib.request.Request("http://127.0.0.1:8000/healthz", headers={"Host":"${publicHostname}"}); urllib.request.urlopen(r,timeout=3)'
          ]
        }
        periodSeconds: 30
        timeoutSeconds: 5
        initialDelaySeconds: 90
      }
    }

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logWorkspaceName
}
resource group 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityResourceId}': {} }
  }
  properties: {
    osType: 'Linux'
    restartPolicy: 'Always'
    diagnostics: {
      logAnalytics: {
        workspaceId: logs.properties.customerId
        workspaceKey: logs.listKeys().primarySharedKey
        logType: 'ContainerInsights'
      }
    }
    imageRegistryCredentials: useManagedIdentityForImagePull ? registryCredentials : []
    initContainers: [
      {
        name: 'journal-permissions'
        properties: {
          image: caddyImage
          command: ['/bin/sh', '-ec', 'chown 10001:10001 /journal; chmod 700 /journal']
          volumeMounts: [
            { name: 'journal-data', mountPath: '/journal' }
          ]
        }
      }
    ]
    ipAddress: {
      type: 'Public'
      dnsNameLabel: dnsLabel
      ports: [
        { port: 80, protocol: 'TCP' }
        { port: 443, protocol: 'TCP' }
      ]
    }
    containers: [
      {
        name: 'app'
        properties: union(
          {
            image: image
            resources: { requests: { cpu: 1, memoryInGB: json('1.5') } }
            environmentVariables: [
              { name: 'TENANT_ID', value: tenantId }
              { name: 'WEB_CLIENT_ID', value: webClientId }
              { name: 'PUBLIC_URL', value: 'https://${publicHostname}' }
              { name: 'OPERATOR_IDS', value: operatorIds }
              { name: 'AUTHORIZED_GROUP_ID', value: authorizedGroupId }
              { name: 'DEMO_TENANT_CONFIRMED', value: 'true' }
              { name: 'DELIVERY_ENABLED', value: string(!bootstrap && deliveryEnabled) }
              { name: 'MAILBOX_SCOPE_CONFIRMED', value: string(mailboxScopeConfirmed) }
              { name: 'ALLOW_EXTERNAL_RECIPIENTS', value: string(allowExternalRecipients) }
              { name: 'MANAGED_IDENTITY_CLIENT_ID', value: identityClientId }
              { name: 'JOURNAL_BLOB_URL', value: '' }
              { name: 'DATA_DIR', value: '/app/data' }
            ]
            volumeMounts: [
              { name: 'journal-data', mountPath: '/app/data' }
            ]
          },
          applicationStartup
        )
      }
      {
        name: 'https'
        properties: {
          image: caddyImage
          command: ['caddy', 'run', '--config', '/etc/demo/Caddyfile', '--adapter', 'caddyfile']
          environmentVariables: [
            { name: 'PUBLIC_HOSTNAME', value: publicHostname }
            { name: 'ACME_EMAIL', value: acmeEmail }
            { name: 'UPSTREAM', value: '127.0.0.1:8000' }
          ]
          resources: { requests: { cpu: json('0.5'), memoryInGB: json('0.5') } }
          ports: [
            { port: 80, protocol: 'TCP' }
            { port: 443, protocol: 'TCP' }
          ]
          volumeMounts: [
            { name: 'caddy-config', mountPath: '/etc/demo', readOnly: true }
            { name: 'caddy-data', mountPath: '/data' }
          ]
        }
      }
    ]
    volumes: [
      { name: 'caddy-config', secret: { Caddyfile: base64(caddyConfig) } }
      {
        name: 'caddy-data'
        emptyDir: {}
      }
      {
        name: 'journal-data'
        emptyDir: {}
      }
    ]
  }
}

output endpoint string = bootstrap ? '' : 'https://${publicHostname}'
output fqdn string = group.properties.ipAddress.fqdn
