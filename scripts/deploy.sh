#!/bin/bash

# deploy.sh - Deploy nginx-demo application to EKS with configurable domain
# Usage: ./deploy.sh [DOMAIN_NAME]
# Example: ./deploy.sh nginx-demo.yourdomain.com

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="nginx-demo"
CLUSTER_CONTEXT="eks-demo-dev-cluster"
REGION="us-west-2"

# Default domain if not provided
DEFAULT_DOMAIN="nginx-demo.novairis.xyz"

# Get domain from argument or use default
DOMAIN_NAME="${1:-$DEFAULT_DOMAIN}"

# Script directory and manifest directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$(dirname "$SCRIPT_DIR")/k8s-manifests"

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to check if command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is required but not installed."
        exit 1
    fi
}

# Function to validate domain format
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_error "Invalid domain format: $domain"
        log_info "Please provide a valid domain name (e.g., nginx-demo.yourdomain.com)"
        exit 1
    fi
}

# Function to check cluster context
check_cluster_context() {
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || echo "none")
    
    if [[ "$current_context" != *"$CLUSTER_CONTEXT"* ]]; then
        log_error "kubectl is not configured for the expected cluster"
        log_info "Current context: $current_context"
        log_info "Expected context to contain: $CLUSTER_CONTEXT"
        log_info "Please configure kubectl to point to your EKS cluster"
        exit 1
    fi
    
    log_success "Connected to cluster: $current_context"
}

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check required commands
    check_command kubectl
    check_command envsubst
    check_command aws
    
    # Check cluster connectivity
    check_cluster_context
    
    # Check if namespace exists
    if ! kubectl get namespace nginx-demo &>/dev/null; then
        log_warning "Namespace 'nginx-demo' does not exist, it will be created"
    fi
    
    # # Check ACM certificate
    # log_info "Checking for ACM certificate for *.${DOMAIN_NAME#*.}"
    # local cert_arn
    # cert_arn=$(aws acm list-certificates --region "$REGION" --query "CertificateSummaryList[?DomainName=='*.${DOMAIN_NAME#*.}'].CertificateArn" --output text)
    
    # if [[ -z "$cert_arn" ]]; then
    #     log_warning "No ACM wildcard certificate found for *.${DOMAIN_NAME#*.}"
    #     log_info "Please ensure you have a valid ACM certificate for your domain"
    #     log_info "The ingress will use automatic certificate discovery"
    # else
    #     log_success "Found ACM certificate: $cert_arn"
    # fi
    
    log_success "Prerequisites check completed"
}

# Function to process templates
process_templates() {
    log_info "Processing templates with domain: $DOMAIN_NAME"
    
    local temp_dir="$SCRIPT_DIR/../temp"
    mkdir -p "$temp_dir"
    
    # Process ingress template
    if [[ -f "$SCRIPT_DIR/../k8s-manifests/03-ingress.yaml.template" ]]; then
        export DOMAIN_NAME
        envsubst < "$SCRIPT_DIR/../k8s-manifests/03-ingress.yaml.template" > "$temp_dir/03-ingress.yaml"
        log_success "Generated ingress manifest for domain: $DOMAIN_NAME"
    else
        log_error "Ingress template not found: $SCRIPT_DIR/../k8s-manifests/03-ingress.yaml.template"
        exit 1
    fi
}

# Function to deploy manifests
deploy_manifests() {
    log_info "Deploying manifests..."
    
    local manifests_dir="$SCRIPT_DIR/../k8s-manifests"
    local temp_dir="$SCRIPT_DIR/../temp"
    
    # Deploy static manifests in order
    for manifest in 00-namespace.yaml 01-deployment.yaml 02-service.yaml 04-hpa.yaml; do
        if [[ -f "$manifests_dir/$manifest" ]]; then
            log_info "Applying $manifest..."
            kubectl apply -f "$manifests_dir/$manifest"
        else
            log_warning "Manifest not found: $manifest"
        fi
    done
    
    # Deploy processed ingress
    if [[ -f "$temp_dir/03-ingress.yaml" ]]; then
        log_info "Applying processed ingress..."
        kubectl apply -f "$temp_dir/03-ingress.yaml"
    else
        log_error "Processed ingress not found"
        exit 1
    fi
    
    log_success "All manifests deployed"
}

# Function to check resource deployment status
check_deployment_status() {
    local retries=5
    local count=0
    
    log_info "Checking deployment status..."
    
    while [[ $count -lt $retries ]]; do
        if kubectl get deployment nginx-demo-deployment -n nginx-demo &>/dev/null; then
            log_success "Deployment found"
            break
        fi
        
        ((count++))
        log_info "Waiting for deployment to be created... (attempt $count/$retries)"
        sleep 5
    done
    
    if [[ $count -eq $retries ]]; then
        log_error "Deployment not found after $retries attempts"
        return 1
    fi
    
    return 0
}

# Function to wait for deployment
wait_for_deployment() {
    log_info "Waiting for all resources to be ready..."
    
    # First check if deployment exists
    if ! check_deployment_status; then
        log_error "Deployment check failed"
        return 1
    fi
    
    # Wait for deployment rollout
    log_info "Waiting for deployment rollout to complete..."
    if kubectl rollout status deployment/nginx-demo-deployment -n nginx-demo --timeout=300s; then
        log_success "Nginx deployment rollout completed"
    else
        log_warning "Deployment rollout may not be complete, checking status..."
        kubectl get deployment nginx-demo-deployment -n nginx-demo
    fi
    
    # Wait for pods to be ready
    log_info "Waiting for pods to be ready..."
    local pod_retries=12
    local pod_count=0
    
    while [[ $pod_count -lt $pod_retries ]]; do
        local ready_pods
        ready_pods=$(kubectl get pods -n nginx-demo -l app=nginx-demo --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        
        if [[ $ready_pods -gt 0 ]]; then
            log_success "$ready_pods pod(s) are running"
            break
        fi
        
        ((pod_count++))
        echo -n "."
        sleep 5
    done
    
    # Wait for ingress
    log_info "Waiting for ingress to get an address..."
    local ingress_retries=30
    local ingress_count=0
    
    while [[ $ingress_count -lt $ingress_retries ]]; do
        local address
        address=$(kubectl get ingress nginx-demo-ingress -n nginx-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        
        if [[ -n "$address" ]]; then
            log_success "Ingress has address: $address"
            break
        fi
        
        ((ingress_count++))
        echo -n "."
        sleep 10
    done
    
    if [[ $ingress_count -eq $ingress_retries ]]; then
        log_warning "Ingress address not available after 5 minutes"
        log_info "You can check the ingress status with: kubectl get ingress -n nginx-demo"
    fi
}

# Function to display comprehensive deployment status
show_deployment_status() {
    log_info "Current deployment status:"
    echo ""
    
    # Namespace
    echo "======================== NAMESPACE ========================"
    kubectl get namespace nginx-demo 2>/dev/null || echo "Namespace not found"
    echo ""
    
    # Deployment
    echo "======================== DEPLOYMENT ========================"
    kubectl get deployment nginx-demo-deployment -n nginx-demo 2>/dev/null || echo "Deployment not found"
    echo ""
    
    # Pods
    echo "======================== PODS ========================"
    kubectl get pods -n nginx-demo -l app=nginx-demo 2>/dev/null || echo "No pods found"
    echo ""
    
    # Service
    echo "======================== SERVICE ========================"
    kubectl get service nginx-demo-service -n nginx-demo 2>/dev/null || echo "Service not found"
    echo ""
    
    # Ingress
    echo "======================== INGRESS ========================"
    kubectl get ingress nginx-demo-ingress -n nginx-demo 2>/dev/null || echo "Ingress not found"
    echo ""
    
    # HPA
    echo "======================== HORIZONTAL POD AUTOSCALER ========================"
    kubectl get hpa nginx-demo-hpa -n nginx-demo 2>/dev/null || echo "HPA not found"
    echo ""
}

# Function to display access information
show_access_info() {
    # Show current status
    show_deployment_status

    log_info "Deployment completed! Access information:"
    echo ""
    echo "Application URL: https://$DOMAIN_NAME"
    echo ""
    echo "To check the status:"
    echo "  kubectl get all -n nginx-demo"
    echo "  kubectl get ingress -n nginx-demo"
    echo ""
    echo "To view logs:"
    echo "  kubectl logs -f deployment/nginx-demo-deployment -n nginx-demo"
    echo ""
    echo "Note: DNS propagation may take a few minutes for the domain to be accessible."
    echo ""
}

# Function to handle deployment errors
handle_deployment_error() {
    log_error "Deployment encountered an error. Showing current status..."
    show_deployment_status
    
    log_info "Troubleshooting tips:"
    echo "1. Check if all prerequisites are met (AWS Load Balancer Controller, External DNS, etc.)"
    echo "2. Verify ACM certificate exists for your domain"
    echo "3. Check cluster permissions and connectivity"
    echo "4. Review the events above for specific error messages"
    echo ""
    echo "To cleanup and retry:"
    echo "  ./cleanup.sh"
    echo "  ./deploy.sh your-domain.com"
}

# Function to cleanup temp files
cleanup() {
    local temp_dir="$SCRIPT_DIR/../temp"
    if [[ -d "$temp_dir" ]]; then
        rm -rf "$temp_dir"
        log_info "Cleaned up temporary files"
    fi
}

# Main execution
main() {
    # Parse arguments
    if [[ $# -eq 0 ]]; then
        log_error "Usage: $0 <domain-name>"
        log_info "Example: $0 nginx-demo.yourdomain.com"
        exit 1
    fi
    
    DOMAIN_NAME="$1"
    validate_domain "$DOMAIN_NAME"
    
    log_info "Starting deployment for domain: $DOMAIN_NAME"
    
    # Setup cleanup trap
    trap cleanup EXIT
    
    # Execute deployment steps with error handling
    if ! check_prerequisites; then
        handle_deployment_error
        exit 1
    fi
    
    if ! process_templates; then
        handle_deployment_error
        exit 1
    fi
    
    if ! deploy_manifests; then
        handle_deployment_error
        exit 1
    fi
    
    if ! wait_for_deployment; then
        log_warning "Deployment may not be fully ready, but continuing..."
        show_deployment_status
    fi
    
    show_access_info
    
    log_success "Deployment completed successfully!"
}

# Run main function with all arguments
main "$@"
