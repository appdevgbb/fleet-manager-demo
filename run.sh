#
# This script automates the deployment of two AKS clusters across different regions in Azure, configures VNet peering, and manages Fleet Manager 
# for multi-cluster layer 4 load balancing.
# It requires Azure CLI and the fleet extension to be installed. The available commands are:
# - deploy: creates AKS clusters in East and West US, peers VNets, and configures Fleet Manager to deploy a demo application across clusters.
# - cleanup: removes all deployed AKS clusters, VNet peering, and Fleet Manager resources.
#
# Usage: ./run.sh {deploy|cleanup}

#!/usr/bin/env bash
# shfmt -i 2 -ci -w
set -e

# Requirements:
# - Azure CLI
# - Azure CLI 'fleet' extension

# ======================
# Environment Variables
# ======================
export LOCATION_EAST="eastus2"
export LOCATION_WEST="westus2"
export RESOURCE_GROUP_EAST="rg-aks-$LOCATION_EAST"
export RESOURCE_GROUP_WEST="rg-aks-$LOCATION_WEST"
export CLUSTER_NAME_EAST="aks-$LOCATION_EAST"
export CLUSTER_NAME_WEST="aks-$LOCATION_WEST"
export FLEET_RESOURCE_GROUP_NAME="rg-fleet"
export FLEET="gbb-fleet"
export FLEET_LOCATION="westus"

# Non-overlapping CIDR ranges
export CIDR_EAST="10.1.0.0/16"
export CIDR_WEST="10.2.0.0/16"

# Subnet names
export SUBNET_NAME_EAST="aks-subnet-east"
export SUBNET_NAME_WEST="aks-subnet-west"

# ======================
# Functions
# ======================

# Error handling function
die() {
    echo "$1" >&2
    #exit 1
}

# Usage function to display help
usage() {
    cat <<EOF
Usage: $0 {deploy|cleanup}

This script automates the deployment of two AKS clusters in East and West US regions,
configures them with Azure Fleet Manager, deploys a demo application across both clusters,
and peers the virtual networks between the clusters.

Commands:
  deploy     Set up AKS clusters, peer the VNets, configure Fleet Manager, and deploy the demo application.
  cleanup    Tear down the AKS clusters, VNet peering, and Fleet Manager resources.

EOF
    exit 1
}

# Create a resource group
create_rg() {
    az group create --name "$1" --location "$2" || die "Failed to create resource group $1"
}

# Create a VNet and Subnet
create_vnet_and_subnet() {
    echo "Creating VNet and Subnet in $1 with CIDR $2"
    az network vnet create --resource-group "$1" --name "$3" --address-prefix "$2" \
        --subnet-name "$4" --subnet-prefix "$5" || die "Failed to create VNet and Subnet in $1"
}

# Get Subnet ID
get_subnet_id() {
    az network vnet subnet show --resource-group "$1" --vnet-name "$2" --name "$3" --query "id" -o tsv || die "Failed to get Subnet ID"
}

# Get VNet ID
get_vnet_id() {
    az network vnet show --resource-group "$1" --name "$2" --query "id" -o tsv || die "Failed to get VNet ID"
}

# Create an AKS cluster with the Subnet ID
create_aks() {
    az aks create --resource-group "$1" --name "$2" --network-plugin azure --vnet-subnet-id "$3" || die "Failed to create AKS cluster $2"
}

# Get credentials for AKS
get_creds() {
    az aks get-credentials --resource-group "$1" --name "$2" --file "$3" || die "Failed to get credentials for $2"
}

# Peer the virtual networks
peer_vnets() {
    echo "Peering VNets between $1 and $2..."

    # Create VNet peering from east to west
    az network vnet peering create --name EastToWestPeering \
        --resource-group "$3" \
        --vnet-name "$4" \
        --remote-vnet "$5" \
        --allow-vnet-access || die "Failed to peer east to west VNets"

    # Create VNet peering from west to east
    az network vnet peering create --name WestToEastPeering \
        --resource-group "$6" \
        --vnet-name "$7" \
        --remote-vnet "$8" \
        --allow-vnet-access || die "Failed to peer west to east VNets"
}

# Get AKS Cluster ID (Managed Cluster Resource ID)
get_cluster_id() {
    az aks show --resource-group "$1" --name "$2" --query "id" -o tsv || die "Failed to get Cluster ID for $2"
}


# Add Fleet extension
add_fleet_ext() {
    az extension add --name fleet || die "Failed to add Fleet extension"
}

# Create Fleet Manager
create_fleet_mgr() {
    az group create --name "$1" --location "$2" || die "Failed to create Fleet resource group $1"
    az fleet create --resource-group "$1" --name "$3" --location "$2" --enable-hub || die "Failed to create Fleet Manager $3"
    
    # Fleet Manager credentials
    az fleet get-credentials --resource-group "$1" --name "$3" --file fleet
}

# Join cluster to Fleet Manager
join_fleet() {
    az fleet member create --resource-group "$1" --fleet-name "$2" --name "$3" --member-cluster-id "$4" || die "Failed to join cluster $3 to Fleet Manager"
}

# Assign role to user
assign_role() {
    IDENTITY=$(az ad signed-in-user show --query "id" --output tsv)
    ROLE="Azure Kubernetes Fleet Manager RBAC Cluster Admin"
    az role assignment create --role "$ROLE" --assignee "$IDENTITY" --scope "$1" || die "Failed to assign role to user"
}

# create the serviceexport
create_service_export() {
    cat <<EOF > aks-store-serviceexport.yaml
apiVersion: networking.fleet.azure.com/v1alpha1
kind: ServiceExport
metadata:
  name: store-front
  namespace: aks-store-demo
EOF
}

# Deploy the AKS store demo
deploy_demo() {
    KUBECONFIG=fleet kubectl create ns aks-store-demo || die "Failed to create namespace"
    KUBECONFIG=fleet kubectl apply -n aks-store-demo -f  https://raw.githubusercontent.com/Azure-Samples/aks-store-demo/main/aks-store-ingress-quickstart.yaml || die "Failed to deploy AKS store ingress"
    KUBECONFIG=fleet kubectl apply -n aks-store-demo -f aks-store-serviceexport.yaml || die "Failed to deploy AKS store deployment"
}

# Create ClusterResourcePlacement
create_crp() {
    cat <<EOF > cluster-resource-placement.yaml
apiVersion: placement.kubernetes-fleet.io/v1beta1
kind: ClusterResourcePlacement
metadata:
  name: aks-store-demo
spec:
  resourceSelectors:
    - group: ""
      version: v1
      kind: Namespace
      name: aks-store-demo
  policy:
    affinity:
      clusterAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          clusterSelectorTerms:
            - labelSelector:
                matchExpressions:
                  - key: fleet.azure.com/location
                    operator: In
                    values:
                      - eastus2
                      - westus2
EOF
    KUBECONFIG=fleet kubectl apply -f cluster-resource-placement.yaml || die "Failed to apply ClusterResourcePlacement"
}

# Validate ClusterResourcePlacement
validate_crp() {
    KUBECONFIG=fleet kubectl get clusterresourceplacement || die "Failed to validate ClusterResourcePlacement"
}

# Validate service export
validate_export() {
    for cluster in east-aks west-aks; do
        echo -e "\n$cluster\n--------"
        KUBECONFIG=$cluster kubectl get serviceexport store-front -n aks-store-demo || die "Failed to validate service export for $cluster"
    done
}

# create the MultiClusterService
create_mcs() {
    cat <<EOF > mcs.yaml
apiVersion: networking.fleet.azure.com/v1alpha1
kind: MultiClusterService
metadata:
  name: store-front
  namespace: aks-store-demo
spec:
  serviceImport:
    name: store-front
EOF
    KUBECONFIG=fleet kubectl apply -f mcs.yaml || die "Failed to create MultiClusterService"
}

# Cleanup function to remove resources
cleanup() {
    echo "Cleaning up resources..."
    az group delete --name ${RESOURCE_GROUP_EAST} --yes --no-wait || die "Failed to delete resource group $RESOURCE_GROUP_EAST"
    az group delete --name ${RESOURCE_GROUP_WEST} --yes --no-wait || die "Failed to delete resource group $RESOURCE_GROUP_WEST"
    az group delete --name ${FLEET_RESOURCE_GROUP_NAME} --yes --no-wait || die "Failed to delete resource group $FLEET_RESOURCE_GROUP_NAME"
}

# ======================
# Main Execution
# ======================
case "$1" in
    deploy)
        # East US VNet and Subnet
        create_rg "$RESOURCE_GROUP_EAST" "$LOCATION_EAST"
        create_vnet_and_subnet "$RESOURCE_GROUP_EAST" "$CIDR_EAST" "aks-vnet-east" "$SUBNET_NAME_EAST" "10.1.0.0/24"
        SUBNET_ID_EAST=$(get_subnet_id "$RESOURCE_GROUP_EAST" "aks-vnet-east" "$SUBNET_NAME_EAST")
        VNET_ID_EAST=$(get_vnet_id "$RESOURCE_GROUP_EAST" "aks-vnet-east")
        CLUSTER_ID_EAST=$(get_cluster_id "$RESOURCE_GROUP_EAST" "$CLUSTER_NAME_EAST")

        # West US VNet and Subnet
        create_rg "$RESOURCE_GROUP_WEST" "$LOCATION_WEST"
        create_vnet_and_subnet "$RESOURCE_GROUP_WEST" "$CIDR_WEST" "aks-vnet-west" "$SUBNET_NAME_WEST" "10.2.0.0/24"
        SUBNET_ID_WEST=$(get_subnet_id "$RESOURCE_GROUP_WEST" "aks-vnet-west" "$SUBNET_NAME_WEST")
        VNET_ID_WEST=$(get_vnet_id "$RESOURCE_GROUP_WEST" "aks-vnet-west")
        CLUSTER_ID_WEST=$(get_cluster_id "$RESOURCE_GROUP_WEST" "$CLUSTER_NAME_WEST")

        # East US AKS cluster
        create_aks "$RESOURCE_GROUP_EAST" "$CLUSTER_NAME_EAST" "$SUBNET_ID_EAST"
        get_creds "$RESOURCE_GROUP_EAST" "$CLUSTER_NAME_EAST" "east-aks"

        # West US AKS cluster
        create_aks "$RESOURCE_GROUP_WEST" "$CLUSTER_NAME_WEST" "$SUBNET_ID_WEST"
        get_creds "$RESOURCE_GROUP_WEST" "$CLUSTER_NAME_WEST" "west-aks"

        # Peer VNets between East and West
        peer_vnets "aks-vnet-east" "aks-vnet-west" "$RESOURCE_GROUP_EAST" "aks-vnet-east" "$VNET_ID_WEST" \
                   "$RESOURCE_GROUP_WEST" "aks-vnet-west" "$VNET_ID_EAST"

        # Fleet Manager
        add_fleet_ext
        create_fleet_mgr "$FLEET_RESOURCE_GROUP_NAME" "$FLEET_LOCATION" "$FLEET"

        # Join clusters to Fleet
        join_fleet "$FLEET_RESOURCE_GROUP_NAME" "$FLEET" "$CLUSTER_NAME_EAST" "$CLUSTER_ID_EAST"
        join_fleet "$FLEET_RESOURCE_GROUP_NAME" "$FLEET" "$CLUSTER_NAME_WEST" "$CLUSTER_ID_WEST"

        # Assign role
        FLEET_ID=$(az fleet show --resource-group "$FLEET_RESOURCE_GROUP_NAME" --name "$FLEET" -o tsv --query=id)
        assign_role "$FLEET_ID"

        # Deploy demo and CRP
        create_service_export
        deploy_demo
        create_crp
        validate_crp

        # Validate service exports
        validate_export
        ;;
    cleanup)
        cleanup
        ;;
    *)
        usage
        ;;
esac
