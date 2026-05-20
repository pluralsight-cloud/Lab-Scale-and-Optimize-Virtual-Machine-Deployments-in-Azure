// Lab infrastructure for "Scale and Optimize Virtual Machine Deployments in Azure".
// CloudCraft accepts variables only, no parameters.
// Deploy: az deployment group create -g $RG --template-file main.bicep
//
// REPLACE `sshPublicKey` below before publishing.

var location           = resourceGroup().location
var vnetName           = 'lab-vnet'
var subnetName         = 'lab-subnet'
var nsgName            = 'vmss-lab-nsg'
var lbName             = 'lab-lb'
var lbPipName          = 'lab-lb-pip'
var lbFrontendName     = 'frontend'
var lbBackendPoolName  = 'backend'
var lbProbeName        = 'tcp-probe-80'
var baselineVmName     = 'lab-baseline-vm'
var baselineVmNicName  = 'lab-baseline-vm-nic'
var baselineVmPipName  = 'lab-baseline-vm-pip'
var vmssName           = 'vmss-lab'
var vmssComputerPrefix = 'vmsslab'

// Sandbox allowlist SKU. Compute-optimized, non-burstable — B-series throttles under sustained
// stress-ng load. Peak: 1 baseline + 3 VMSS = 8 vCPU (cap 10), 4 GB/instance (cap 14).
var vmSize = 'Standard_D2s_v3'

// Autoscale max in Objective 2 is 3 (sandbox per-scale-set ceiling).
var vmssCapacity = 2

var adminUsername = 'labadmin'

// REPLACE: must pair with the private key the lab platform stages at ~/.ssh/lab_key.
var sshPublicKey = 'ssh-rsa AAAA__REPLACE_WITH_LAB_PUBLIC_KEY__ lab@pluralsight'

// Pre-installs stress-ng so Objective 3 works after lab egress closes.
var cloudInit = '''
#cloud-config
package_update: true
packages:
  - stress-ng
'''

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: location
  properties: {
    // Learner adds AllowSSHInbound in Objective 3.
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource lbPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: lbPipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// Architectural scaffolding for a future web tier. Nothing listens on 80 today,
// so the probe will report Unhealthy until something does.
resource lb 'Microsoft.Network/loadBalancers@2023-09-01' = {
  name: lbName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: lbFrontendName
        properties: {
          publicIPAddress: {
            id: lbPip.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: lbBackendPoolName
      }
    ]
    probes: [
      {
        name: lbProbeName
        properties: {
          protocol: 'Tcp'
          port: 80
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'http-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, lbFrontendName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, lbBackendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, lbProbeName)
          }
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          idleTimeoutInMinutes: 4
          enableFloatingIP: false
          loadDistribution: 'Default'
        }
      }
    ]
  }
}

resource baselineVmPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: baselineVmPipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource baselineVmNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: baselineVmNicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${vnet.id}/subnets/${subnetName}'
          }
          publicIPAddress: {
            id: baselineVmPip.id
          }
        }
      }
    ]
  }
}

resource baselineVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: baselineVmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    osProfile: {
      computerName: baselineVmName
      // CloudCraft forbids params; literal is intentional.
      #disable-next-line adminusername-should-not-be-literal
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
      customData: base64(cloudInit)
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: baselineVmNic.id
        }
      ]
    }
  }
}

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: vmssName
  location: location
  sku: {
    name: vmSize
    capacity: vmssCapacity
  }
  properties: {
    orchestrationMode: 'Uniform'
    upgradePolicy: {
      mode: 'Manual'
    }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: vmssComputerPrefix
        // CloudCraft forbids params; literal is intentional.
        #disable-next-line adminusername-should-not-be-literal
        adminUsername: adminUsername
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: sshPublicKey
              }
            ]
          }
        }
        customData: base64(cloudInit)
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: {
            storageAccountType: 'Standard_LRS'
          }
        }
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'vmss-nic'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig1'
                  properties: {
                    subnet: {
                      id: '${vnet.id}/subnets/${subnetName}'
                    }
                    // Per-instance public IP so Cloud Shell can SSH to a specific instance.
                    publicIPAddressConfiguration: {
                      name: 'instance-pip'
                      properties: {
                        idleTimeoutInMinutes: 4
                      }
                    }
                    loadBalancerBackendAddressPools: [
                      {
                        id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, lbBackendPoolName)
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
    }
  }
  // Backend pool referenced via resourceId() (string), so Bicep can't infer this dep.
  dependsOn: [
    lb
  ]
}
