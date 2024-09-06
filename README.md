# Pattern - Multi-Cluster Layer 4 Load Balancer with Azure Fleet Manager

This repository contains scripts to deploy a multi-cluster layer 4 load balancer across Azure Kubernetes Service (AKS) clusters in different regions using Azure Fleet Manager.

### Topology

```
+-----------------------+          +-----------------------+
|    AKS Cluster (East) |          |    AKS Cluster (West) |
|  Region: East US      |          |  Region: West US      |
|                       |          |                       |
| +-------------------+ |          | +-------------------+ |
| |   Application     | |          | |   Application     | |
| +-------------------+ |          | +-------------------+ |
|                       |          |                       |
+-----------------------+          +-----------------------+
          |                                      |
          +--------------------------------------+
                        VNet Peering

             +-----------------------------------+
             |    Fleet Manager (Hub Region)     |
             +-----------------------------------+
```

- [x] AKS Cluster (East): A Kubernetes cluster deployed in the East US region.
- [x] AKS Cluster (West): A Kubernetes cluster deployed in the West US region.
- [x] VNet Peering: Virtual Network peering between the AKS clusters to enable communication.
- [x] Fleet Manager: Azure Fleet Manager deployed in the hub region, managing the application across both AKS clusters.

### Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- Azure CLI `fleet` extension: Install it using the following command:
   ```bash
   az extension add --name fleet
  ```
### Steps to run this demo

To deploy the AKS clusters and set up Fleet Manager, follow these steps:

Clone this repository:

```bash
git clone https://github.com/appdevgbb/fleet-manager-demo.git
cd fleet-manager-demo
```

Deploy the AKS clusters and configure Fleet Manager:
```bash
./run.sh deploy
```

Monitor the progress of the deployment in the terminal.

To remove the entire deployment:

Run the following command:
```bash
./run.sh cleanup
```
Usage:

```bash
./run.sh 
Usage: ./run.sh {deploy|cleanup}

This script automates the deployment of two AKS clusters in East and West US regions,
configures them with Azure Fleet Manager, deploys a demo application across both clusters,
and peers the virtual networks between the clusters.

Commands:
  deploy     Set up AKS clusters, peer the VNets, configure Fleet Manager, and deploy the demo application.
  cleanup    Tear down the AKS clusters, VNet peering, and Fleet Manager resources.
```
