# Nginx Demo - Production-Ready Kubernetes Deployment on AWS EKS

## 📁 Project Structure

This directory contains a complete, production-ready Kubernetes deployment package for nginx on AWS EKS with automatic scaling and public HTTPS access.

### Directory Structure

```
assignment-1/
├── README.md                           # Comprehensive deployment documentation
├── DISASTER-RECOVERY.md               # DR procedures and backup strategies
├── k8s-manifests/                     # Production-ready Kubernetes manifests
│   ├── 00-namespace.yaml             # Dedicated namespace for nginx-demo
│   ├── 01-deployment.yaml             # Nginx deployment with security & health checks
│   ├── 02-service.yaml               # ClusterIP service for internal networking
│   ├── 03-ingress.yaml               # ALB ingress with ACM certificate integration
│   ├── 03-ingress.yaml.template      # Template for configurable domain deployment
│   └── 04-hpa.yaml                   # Horizontal Pod Autoscaler configuration
└── scripts/                           # Deployment automation scripts
    ├── deploy.sh                      # Automated deployment script with domain configuration
    └── cleanup.sh                     # Environment cleanup script
```

## ✨ Key Features

- **Production Security**: Non-root containers, read-only filesystems, security contexts
- **High Availability**: Multi-AZ pod distribution, pod disruption budgets
- **Auto-Scaling**: HPA with CPU/memory metrics (2-10 replicas)
- **SSL/TLS**: AWS Certificate Manager (ACM) integration for automatic HTTPS
- **Load Balancing**: AWS Application Load Balancer with health checks
- **DNS Management**: External DNS with Route53 integration
- **Monitoring**: Health endpoints, Prometheus-ready metrics, nginx status page

### Quick Access
```bash
# Test the application
curl https://nginx-demo.your-domain.com/

# Test health endpoint  
curl https://nginx-demo.your-domain.com/health

# Check deployment status
kubectl get all -n nginx-demo
```

## EKS Prerequisites

### Required AWS Infrastructure

Before deploying this application, ensure your EKS cluster has:

1. **VPC with Proper Subnet Tags**:
   - Public subnets: `kubernetes.io/role/elb = 1`
   - Private subnets: `kubernetes.io/role/internal-elb = 1`

2. **Route53 Hosted Zone**: For your domain with proper NS records

3. **EKS Add-ons Ready**: The following must be installed and configured:
   - AWS Load Balancer Controller with proper IAM roles
   - External DNS with Route53 permissions
   - ACM certificate for your domain (*.your-domain.com)
   - Metrics Server for HPA



### Configure kubectl for EKS

Before deploying, ensure your kubectl is configured to connect to your EKS cluster:

```bash
# Update kubeconfig for your EKS cluster
aws eks update-kubeconfig --region your-region --name your-cluster-name

# Example:
aws eks update-kubeconfig --region us-west-2 --name my-eks-cluster

# Verify connection
kubectl config current-context
kubectl get nodes
```

### Quick Verification

```bash
# Verify cluster connectivity and configuration
kubectl config current-context

# Check required add-ons
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get deployment -n kube-system external-dns  
kubectl get deployment -n kube-system metrics-server

# Verify ACM certificates
aws acm list-certificates --region your-region

# Note: Make sure to use the same region configured in scripts/deploy.sh
```

## Configuration

This deployment is designed for an EKS cluster with the following setup:
- **Cluster Name**: `your-cluster-name`
- **Region**: `us-west-2` (or your preferred region)
- **Domain**: `your-domain.com`
- **Hostname**: `nginx-demo.your-domain.com`

## 📋 Components Deployed

1. **Namespace**: Isolated environment for the application
2. **Deployment**: nginx with 2 replicas, security hardening, health checks, custom config
3. **ConfigMap**: Custom nginx configuration with security headers and monitoring endpoints
4. **Service**: ClusterIP for internal communication
5. **Ingress**: AWS ALB with HTTPS via ACM certificates
6. **HPA**: CPU/memory-based scaling (50% threshold, 2-10 replicas)

## 🔧 Customization Options

### Domain Configuration
The deployment supports flexible domain configuration through template-based manifests:

- **Automated**: Use the `deploy.sh` script with your domain as a parameter
- **Template-based**: The `03-ingress.yaml.template` uses `${DOMAIN_NAME}` variable for envsubst processing
- **Manual**: Update domain directly in `03-ingress.yaml` for static deployments

### Other Customizations
- **Resources**: Adjust CPU/memory requests and limits in deployment
- **Scaling**: Modify HPA thresholds and replica counts (currently 50% CPU/memory, 2-10 replicas)
- **Security**: Add network policies, update security contexts
- **Monitoring**: Integrate with Prometheus/Grafana using existing annotations
- **Load Balancer**: Customize ALB settings via ingress annotations

## 🎯 Quick Deployment

### Step 0: Configure Script (Required)

**Before deploying, you must configure the deployment script:**

1. **Update script configuration**:
   ```bash
   # Edit scripts/deploy.sh and update these values:
   CLUSTER_CONTEXT="your-eks-cluster-context"  # Your actual EKS cluster context
   REGION="your-aws-region"                    # Your AWS region (e.g., us-east-1, eu-west-1)
   ```

2. **Configure kubectl for your EKS cluster**:
   ```bash
   # Update kubeconfig for your EKS cluster
   aws eks update-kubeconfig --region your-region --name your-cluster-name
   
   # Verify connection
   kubectl config current-context
   kubectl get nodes
   ```

### Option 1: Automated Deployment Script (Recommended)

The simplest way to deploy the application with a custom domain:

```bash
# Navigate to the scripts directory
cd scripts

# Deploy with your domain name
./deploy.sh your-domain.yourdomain.com

# Example:
./deploy.sh nginx-demo.mycompany.com
```

**The script will automatically:**
- Validate your domain format
- Check all prerequisites (kubectl, envsubst, AWS CLI)
- Verify cluster connectivity and ACM certificates
- Process domain templates using envsubst
- Deploy all manifests in the correct order
- Monitor deployment progress
- Display access information

### Option 2: Manual Deployment

For manual control or troubleshooting, you can deploy individual components:

```bash
# Ensure you have configured kubectl for your EKS cluster first:
# aws eks update-kubeconfig --region your-region --name your-cluster-name

# Verify you're connected to the correct cluster
kubectl config current-context

# Should show your EKS cluster context

# Verify required components are running
kubectl get pods -n kube-system | grep -E "(aws-load-balancer-controller|external-dns)"
kubectl get deployment metrics-server -n kube-system

# Navigate to the manifests directory
cd k8s-manifests

# 1. Create namespace
kubectl apply -f 00-namespace.yaml

# 2. Deploy the application (includes ConfigMap)
kubectl apply -f 01-deployment.yaml

# 3. Create service
kubectl apply -f 02-service.yaml

# 4. Setup auto-scaling
kubectl apply -f 04-hpa.yaml

# 5. Deploy ingress with ACM integration
kubectl apply -f 03-ingress.yaml
```

### Step 3: Monitor Deployment Progress

```bash
# Watch deployment rollout
kubectl rollout status deployment/nginx-demo-deployment -n nginx-demo

# Monitor ingress creation and ALB provisioning
kubectl get ingress -n nginx-demo -w

# Check ALB status and get hostname
kubectl describe ingress nginx-demo-ingress -n nginx-demo
```

### Step 4: Verify DNS and HTTPS Access

```bash
# The ingress will automatically:
# 1. Provision an ALB
# 2. Create Route53 DNS record for nginx-demo.your-domain.com
# 3. Attach ACM certificate for HTTPS

# Wait for DNS propagation (usually 1-5 minutes)
nslookup nginx-demo.your-domain.com

# Test HTTP (redirects to HTTPS if configured)
curl -I http://nginx-demo.your-domain.com

# Test HTTPS
curl -I https://nginx-demo.your-domain.com

# Test health endpoint
curl https://nginx-demo.your-domain.com/health
```

## 🔍 Verification Commands

### Application Health
```bash
# Check all resources
kubectl get all -n nginx-demo

# Check pod logs
kubectl logs -l app=nginx-demo -n nginx-demo --tail=50

# Test health endpoint
curl https://nginx-demo.your-domain.com/health

# Test nginx status endpoint (internal monitoring)
curl https://nginx-demo.your-domain.com/nginx_status

# Port-forward for direct testing
kubectl port-forward -n nginx-demo deployment/nginx-demo-deployment 8080:8080
curl http://localhost:8080/nginx_status
```

### Auto-Scaling Verification
```bash
# Check HPA status
kubectl get hpa -n nginx-demo

# Check resource metrics
kubectl top pods -n nginx-demo
kubectl top nodes

# Generate load for testing
kubectl run -i --tty load-generator --rm --image=busybox --restart=Never -- /bin/sh
# Inside the pod:
while true; do wget -q -O- https://nginx-demo.your-domain.com; done
```

### Certificate and Ingress Status
```bash
# Check ingress status and ALB details
kubectl describe ingress nginx-demo-ingress -n nginx-demo

# Check ACM certificate status
aws acm list-certificates --region us-west-2
aws acm describe-certificate --certificate-arn <CERTIFICATE_ARN> --region us-west-2

# Check ALB listeners for HTTPS configuration
aws elbv2 describe-listeners --load-balancer-arn <ALB_ARN> --region us-west-2

# Check DNS records
dig nginx-demo.your-domain.com
```

## 🧹 Cleanup

### Using the Cleanup Script

```bash
# Navigate to the scripts directory
cd scripts

# Run the cleanup script to remove all resources
./cleanup.sh

# Verify cleanup
kubectl get all -n nginx-demo
```

The cleanup script will:
- Delete all application resources from the nginx-demo namespace
- Remove the namespace itself
- ALB and Route53 records are automatically cleaned up by the controllers

### Manual Cleanup

If you prefer manual cleanup:

```bash
# Delete all application resources
kubectl delete namespace nginx-demo

# Verify no resources remain
kubectl get all -n nginx-demo
```