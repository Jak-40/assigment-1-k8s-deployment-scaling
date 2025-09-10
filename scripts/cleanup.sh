#!/bin/bash

# Nginx Demo Cleanup Script
# Description: Clean up all resources created by the nginx demo deployment
# Usage: ./cleanup.sh [OPTIONS]

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="nginx-demo"
MANIFEST_DIR="./k8s-manifests"
FORCE_CLEANUP=false
DRY_RUN=false
CLEANUP_CLUSTER_RESOURCES=false

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to confirm action
confirm_action() {
    if [[ "$FORCE_CLEANUP" != "true" ]]; then
        echo -e "${YELLOW}WARNING: This will delete all nginx demo resources!${NC}"
        echo "Resources to be deleted:"
        echo "  - Namespace: $NAMESPACE (and all resources within)"
        if [[ "$CLEANUP_CLUSTER_RESOURCES" == "true" ]]; then
            echo "  - ClusterIssuers: letsencrypt-prod, letsencrypt-staging, selfsigned-issuer"
        fi
        echo ""
        read -p "Are you sure you want to continue? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            print_status "Cleanup cancelled by user"
            exit 0
        fi
    fi
}

# Function to cleanup namespace and resources
cleanup_namespace() {
    local dry_run_flag=""
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run_flag="--dry-run=client"
    fi
    
    print_status "Cleaning up namespace: $NAMESPACE"
    
    if kubectl get namespace $NAMESPACE &> /dev/null; then
        # Delete the namespace (this will delete all resources within it)
        kubectl delete namespace $NAMESPACE $dry_run_flag
        print_success "Namespace $NAMESPACE deleted"
        
        if [[ "$DRY_RUN" != "true" ]]; then
            # Wait for namespace deletion to complete
            print_status "Waiting for namespace deletion to complete..."
            local timeout=300
            local elapsed=0
            
            while kubectl get namespace $NAMESPACE &> /dev/null && [[ $elapsed -lt $timeout ]]; do
                sleep 5
                elapsed=$((elapsed + 5))
                if [[ $((elapsed % 30)) -eq 0 ]]; then
                    print_status "Still waiting for namespace deletion... ($elapsed/$timeout seconds)"
                fi
            done
            
            if kubectl get namespace $NAMESPACE &> /dev/null; then
                print_warning "Namespace deletion is taking longer than expected"
                print_warning "You may need to manually check for stuck resources"
            else
                print_success "Namespace deletion completed"
            fi
        fi
    else
        print_warning "Namespace $NAMESPACE not found"
    fi
}

# Function to cleanup cluster-wide resources
cleanup_cluster_resources() {
    local dry_run_flag=""
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run_flag="--dry-run=client"
    fi
    
    print_status "Cleaning up cluster-wide resources..."
    
    # ClusterIssuers
    local cluster_issuers=("letsencrypt-prod" "letsencrypt-staging" "selfsigned-issuer")
    
    for issuer in "${cluster_issuers[@]}"; do
        if kubectl get clusterissuer $issuer &> /dev/null; then
            kubectl delete clusterissuer $issuer $dry_run_flag
            print_success "ClusterIssuer $issuer deleted"
        else
            print_warning "ClusterIssuer $issuer not found"
        fi
    done
}

# Function to cleanup AWS resources
cleanup_aws_resources() {
    if [[ "$DRY_RUN" == "true" ]]; then
        print_status "DRY RUN: Would check for AWS resources to cleanup"
        return
    fi
    
    print_status "Checking for AWS resources that may need manual cleanup..."
    
    # Check for ALBs that might not have been automatically deleted
    if command -v aws &> /dev/null; then
        print_status "Checking for Application Load Balancers..."
        
        # List ALBs with nginx-demo tags
        local albs=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName, `nginx-demo`)].LoadBalancerArn' --output text 2>/dev/null || echo "")
        
        if [[ -n "$albs" ]]; then
            print_warning "Found ALBs that may need manual cleanup:"
            echo "$albs"
            print_warning "Use: aws elbv2 delete-load-balancer --load-balancer-arn <ARN>"
        fi
        
        # Check for security groups
        print_status "Checking for security groups..."
        local cluster_name=$(kubectl config current-context | cut -d'/' -f2 2>/dev/null || echo "unknown")
        if [[ "$cluster_name" != "unknown" ]]; then
            local sgs=$(aws ec2 describe-security-groups --filters "Name=tag:kubernetes.io/cluster/$cluster_name,Values=shared" --query 'SecurityGroups[?contains(GroupName, `nginx-demo`)].GroupId' --output text 2>/dev/null || echo "")
            
            if [[ -n "$sgs" ]]; then
                print_warning "Found security groups that may need manual cleanup:"
                echo "$sgs"
                print_warning "Review and delete if no longer needed"
            fi
        fi
    else
        print_warning "AWS CLI not found. Please manually check for AWS resources."
    fi
}

# Function to show remaining resources
show_remaining_resources() {
    print_status "Checking for any remaining resources..."
    
    # Check if namespace still exists
    if kubectl get namespace $NAMESPACE &> /dev/null; then
        print_warning "Namespace $NAMESPACE still exists"
        kubectl get all -n $NAMESPACE 2>/dev/null || true
    fi
    
    # Check cluster issuers
    print_status "Remaining ClusterIssuers:"
    kubectl get clusterissuers 2>/dev/null || print_status "No ClusterIssuers found"
    
    # Check for any pods/resources that might be stuck
    print_status "Checking for stuck resources..."
    local stuck_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Terminating 2>/dev/null | grep -v "No resources found" || echo "")
    if [[ -n "$stuck_pods" ]]; then
        print_warning "Found pods stuck in Terminating state:"
        echo "$stuck_pods"
        print_warning "You may need to force delete them with: kubectl delete pod <pod-name> --force --grace-period=0"
    fi
}

# Function to restore backups if they exist
restore_backups() {
    print_status "Checking for backup files..."
    
    if ls "$MANIFEST_DIR"/*.bak 1> /dev/null 2>&1; then
        print_status "Found backup files. Restoring original manifests..."
        for backup in "$MANIFEST_DIR"/*.bak; do
            original="${backup%.bak}"
            mv "$backup" "$original"
            print_success "Restored $(basename "$original")"
        done
    else
        print_status "No backup files found"
    fi
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Clean up nginx demo application resources from AWS EKS cluster.

OPTIONS:
    -f, --force            Force cleanup without confirmation prompt
    -c, --cluster          Also cleanup cluster-wide resources (ClusterIssuers)
    -d, --dry-run          Show what would be deleted without actually deleting
    -r, --restore          Restore original manifest files from backups
    -h, --help             Display this help message

EXAMPLES:
    $0                     Interactive cleanup of namespace resources only
    $0 --force             Force cleanup without prompts
    $0 --cluster           Cleanup including cluster-wide resources
    $0 --dry-run           Show what would be deleted
    $0 --restore           Only restore original manifest files

NOTES:
    - By default, only namespace and resources within it are deleted
    - Use --cluster flag to also delete ClusterIssuers
    - AWS resources (ALBs, Security Groups) may need manual cleanup
    - Always verify cluster state after cleanup

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE_CLEANUP=true
            shift
            ;;
        -c|--cluster)
            CLEANUP_CLUSTER_RESOURCES=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -r|--restore)
            restore_backups
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    print_status "Starting nginx demo cleanup..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_status "DRY RUN MODE - No resources will be actually deleted"
    fi
    
    # Confirm action
    confirm_action
    
    # Cleanup namespace and its resources
    cleanup_namespace
    
    # Cleanup cluster-wide resources if requested
    if [[ "$CLEANUP_CLUSTER_RESOURCES" == "true" ]]; then
        cleanup_cluster_resources
    fi
    
    # Check for AWS resources that might need manual cleanup
    cleanup_aws_resources
    
    # Show any remaining resources
    if [[ "$DRY_RUN" != "true" ]]; then
        show_remaining_resources
    fi
    
    # Restore backup files
    if [[ "$DRY_RUN" != "true" ]]; then
        restore_backups
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_success "Dry run completed!"
    else
        print_success "Cleanup completed!"
        echo ""
        print_status "Summary:"
        echo "  ✓ Namespace '$NAMESPACE' and all resources within it have been deleted"
        if [[ "$CLEANUP_CLUSTER_RESOURCES" == "true" ]]; then
            echo "  ✓ Cluster-wide resources (ClusterIssuers) have been deleted"
        fi
        echo "  ✓ Original manifest files have been restored from backups"
        echo ""
        print_warning "Note: Please check AWS Console for any remaining ALBs or Security Groups"
        print_warning "that may need manual cleanup to avoid ongoing charges."
    fi
}

# Run main function
main "$@"
