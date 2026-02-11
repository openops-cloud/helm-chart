# Deploy OpenOps to AWS EKS (EC2)

This guide walks through deploying the OpenOps Helm chart to a new Amazon EKS cluster running on EC2 instances. It covers infrastructure setup, production-grade configuration, and operational best practices for AWS.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Provision EKS Cluster](#provision-eks-cluster)
3. [Configure AWS Resources](#configure-aws-resources)
4. [Prepare Helm Configuration](#prepare-helm-configuration)
5. [Deploy OpenOps](#deploy-openops)
6. [Post-Deployment Configuration](#post-deployment-configuration)
7. [Monitoring and Operations](#monitoring-and-operations)
8. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required Tools
Install the following tools on your workstation:

```bash
# AWS CLI (version 2.x)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# kubectl (compatible with your EKS version)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# eksctl (for EKS cluster management)
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# Helm 3.x
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Optional: AWS IAM Authenticator (usually bundled with kubectl)
curl -Lo aws-iam-authenticator https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/v0.6.14/aws-iam-authenticator_0.6.14_linux_amd64
chmod +x aws-iam-authenticator
sudo mv aws-iam-authenticator /usr/local/bin/
```

### AWS Account Configuration
```bash
# Configure AWS credentials
aws configure
# Enter your Access Key ID, Secret Access Key, region (e.g., us-east-1), and output format (json)

# Verify credentials
aws sts get-caller-identity

# Set environment variables (optional but recommended)
export AWS_REGION=us-east-1
export CLUSTER_NAME=openops-production
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

### Resource Requirements
For a production OpenOps deployment, budget for:
- **EKS cluster**: 3 EC2 instances minimum (t3.xlarge or larger recommended)
- **RDS PostgreSQL**: db.t3.large or higher (50GB+ storage)
- **ElastiCache Redis**: cache.t3.medium or higher
- **EBS volumes**: ~100GB for PVCs (gp3 storage class)
- **Network Load Balancer**: For nginx service exposure
- **VPC**: Dedicated VPC with public and private subnets across 3 AZs

**Estimated monthly cost**: $500-1000 USD depending on instance sizes and data transfer.

---

## Provision EKS Cluster

### Option 1: Using eksctl (Recommended)

Create an `eksctl` configuration file for infrastructure-as-code:

```yaml
# eks-cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: openops-production
  region: us-east-1
  version: "1.29"  # Use latest stable EKS version

# Enable private endpoint access for security
vpc:
  clusterEndpoints:
    publicAccess: true
    privateAccess: true
  nat:
    gateway: HighlyAvailable  # NAT Gateway in each AZ

# IAM OIDC provider for IRSA (IAM Roles for Service Accounts)
iam:
  withOIDC: true
  serviceAccounts:
    - metadata:
        name: openops-app
        namespace: openops
      roleName: openops-app-role
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
    - metadata:
        name: openops-engine
        namespace: openops
      roleName: openops-engine-role
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonS3FullAccess
    - metadata:
        name: ebs-csi-controller-sa
        namespace: kube-system
      wellKnownPolicies:
        ebsCSIController: true
    - metadata:
        name: aws-load-balancer-controller
        namespace: kube-system
      wellKnownPolicies:
        awsLoadBalancerController: true

# Add-ons
addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
  - name: aws-ebs-csi-driver
    version: latest
    serviceAccountRoleARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole

# Managed node group
managedNodeGroups:
  - name: openops-ng-1
    instanceType: t3.xlarge
    desiredCapacity: 3
    minSize: 3
    maxSize: 6
    volumeSize: 100
    volumeType: gp3
    labels:
      role: openops
      environment: production
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/openops-production: "owned"
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        externalDNS: true
        certManager: true
        ebs: true
        efs: true
        albIngress: true
        cloudWatch: true
    privateNetworking: true
    ssh:
      allow: true
      publicKeyName: your-ec2-keypair  # Optional: for SSH access

# CloudWatch logging
cloudWatch:
  clusterLogging:
    enableTypes:
      - api
      - audit
      - authenticator
      - controllerManager
      - scheduler
```

Create the cluster:

```bash
# Create cluster (takes 15-20 minutes)
eksctl create cluster -f eks-cluster.yaml

# Verify cluster
kubectl get nodes
kubectl get pods -A

# Update kubeconfig
aws eks update-kubeconfig --region us-east-1 --name openops-production
```

### Option 2: Using Terraform

```hcl
# main.tf
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "openops-production"
  cluster_version = "1.29"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    openops_nodes = {
      min_size     = 3
      max_size     = 6
      desired_size = 3

      instance_types = ["t3.xlarge"]
      capacity_type  = "ON_DEMAND"

      tags = {
        Environment = "production"
        Application = "openops"
      }
    }
  }
}
```

### Install Essential Add-ons

```bash
# 1. Install AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=openops-production \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# 2. Install Metrics Server (required for HPA)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 3. Install EBS CSI Driver (if not added via eksctl)
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  -n kube-system \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=ebs-csi-controller-sa

# 4. Optional: Install Cluster Autoscaler
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=openops-production \
  --set awsRegion=us-east-1
```

---

## Configure AWS Resources

### 1. Create RDS PostgreSQL Database

```bash
# Set variables
export DB_NAME=openops
export DB_USERNAME=openops_admin
export DB_PASSWORD=$(openssl rand -base64 32)  # Save this securely!

# Create DB subnet group
aws rds create-db-subnet-group \
  --db-subnet-group-name openops-db-subnet \
  --db-subnet-group-description "OpenOps RDS subnet group" \
  --subnet-ids subnet-xxxxx subnet-yyyyy subnet-zzzzz \
  --region $AWS_REGION

# Create security group for RDS
export RDS_SG=$(aws ec2 create-security-group \
  --group-name openops-rds-sg \
  --description "Security group for OpenOps RDS" \
  --vpc-id vpc-xxxxx \
  --region $AWS_REGION \
  --query 'GroupId' --output text)

# Allow inbound PostgreSQL traffic from EKS worker nodes
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG \
  --protocol tcp \
  --port 5432 \
  --source-group <eks-worker-node-sg> \
  --region $AWS_REGION

# Create RDS instance
aws rds create-db-instance \
  --db-instance-identifier openops-production-db \
  --db-instance-class db.t3.large \
  --engine postgres \
  --engine-version 15.4 \
  --master-username $DB_USERNAME \
  --master-user-password "$DB_PASSWORD" \
  --allocated-storage 100 \
  --storage-type gp3 \
  --iops 3000 \
  --storage-encrypted \
  --db-subnet-group-name openops-db-subnet \
  --vpc-security-group-ids $RDS_SG \
  --backup-retention-period 7 \
  --preferred-backup-window "03:00-04:00" \
  --preferred-maintenance-window "mon:04:00-mon:05:00" \
  --multi-az \
  --publicly-accessible false \
  --region $AWS_REGION

# Wait for DB to be available (takes 5-10 minutes)
aws rds wait db-instance-available \
  --db-instance-identifier openops-production-db \
  --region $AWS_REGION

# Get DB endpoint
export DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier openops-production-db \
  --region $AWS_REGION \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

echo "RDS Endpoint: $DB_ENDPOINT"

# Create databases
# Connect using psql from a pod or EC2 instance in the VPC
PGPASSWORD="$DB_PASSWORD" psql -h $DB_ENDPOINT -U $DB_USERNAME -d postgres << EOF
CREATE DATABASE openops;
CREATE DATABASE tables;
\q
EOF
```

**Alternative: Using RDS via AWS Console**
1. Navigate to RDS → Create database
2. Choose PostgreSQL 15.x
3. Select Production template
4. Configure:
   - DB instance identifier: `openops-production-db`
   - Master username: `openops_admin`
   - Master password: (generate strong password)
   - Instance size: `db.t3.large`
   - Storage: 100GB gp3 with autoscaling
   - Multi-AZ: Yes
   - VPC: Same as EKS cluster
   - Public access: No
   - Security group: Allow 5432 from EKS worker nodes
5. Enable automated backups (7-day retention)
6. Create databases: `openops` and `tables`

### 2. Create ElastiCache Redis Cluster

```bash
# Create cache subnet group
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name openops-redis-subnet \
  --cache-subnet-group-description "OpenOps Redis subnet group" \
  --subnet-ids subnet-xxxxx subnet-yyyyy subnet-zzzzz \
  --region $AWS_REGION

# Create security group for Redis
export REDIS_SG=$(aws ec2 create-security-group \
  --group-name openops-redis-sg \
  --description "Security group for OpenOps Redis" \
  --vpc-id vpc-xxxxx \
  --region $AWS_REGION \
  --query 'GroupId' --output text)

# Allow inbound Redis traffic from EKS worker nodes
aws ec2 authorize-security-group-ingress \
  --group-id $REDIS_SG \
  --protocol tcp \
  --port 6379 \
  --source-group <eks-worker-node-sg> \
  --region $AWS_REGION

# Create Redis replication group (cluster mode disabled)
aws elasticache create-replication-group \
  --replication-group-id openops-production-redis \
  --replication-group-description "OpenOps Redis cluster" \
  --engine redis \
  --engine-version 7.0 \
  --cache-node-type cache.t3.medium \
  --num-cache-clusters 2 \
  --automatic-failover-enabled \
  --cache-subnet-group-name openops-redis-subnet \
  --security-group-ids $REDIS_SG \
  --at-rest-encryption-enabled \
  --transit-encryption-enabled \
  --auth-token "$(openssl rand -base64 32)" \
  --snapshot-retention-limit 5 \
  --snapshot-window "03:00-05:00" \
  --preferred-maintenance-window "mon:05:00-mon:07:00" \
  --region $AWS_REGION

# Wait for Redis to be available (takes 5-10 minutes)
aws elasticache wait replication-group-available \
  --replication-group-id openops-production-redis \
  --region $AWS_REGION

# Get Redis endpoint
export REDIS_ENDPOINT=$(aws elasticache describe-replication-groups \
  --replication-group-id openops-production-redis \
  --region $AWS_REGION \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' \
  --output text)

echo "Redis Endpoint: $REDIS_ENDPOINT"
```

### 3. Create S3 Bucket for File Storage (Optional)

```bash
# Create S3 bucket for user uploads and backups
aws s3api create-bucket \
  --bucket openops-production-storage-${AWS_ACCOUNT_ID} \
  --region $AWS_REGION \
  --create-bucket-configuration LocationConstraint=$AWS_REGION

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket openops-production-storage-${AWS_ACCOUNT_ID} \
  --versioning-configuration Status=Enabled

# Enable server-side encryption
aws s3api put-bucket-encryption \
  --bucket openops-production-storage-${AWS_ACCOUNT_ID} \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket openops-production-storage-${AWS_ACCOUNT_ID} \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Create lifecycle policy for cost optimization
cat > lifecycle-policy.json << 'EOF'
{
  "Rules": [{
    "Id": "archive-old-versions",
    "Status": "Enabled",
    "NoncurrentVersionTransitions": [{
      "NoncurrentDays": 90,
      "StorageClass": "GLACIER"
    }],
    "NoncurrentVersionExpiration": {
      "NoncurrentDays": 365
    }
  }]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket openops-production-storage-${AWS_ACCOUNT_ID} \
  --lifecycle-configuration file://lifecycle-policy.json
```

### 4. Create ACM Certificate for HTTPS

```bash
# Request certificate from ACM
export CERT_ARN=$(aws acm request-certificate \
  --domain-name openops.example.com \
  --domain-name "*.openops.example.com" \
  --validation-method DNS \
  --region $AWS_REGION \
  --query 'CertificateArn' \
  --output text)

# Get DNS validation records
aws acm describe-certificate \
  --certificate-arn $CERT_ARN \
  --region $AWS_REGION

# Add the CNAME records to your DNS (Route53 or external DNS provider)
# For Route53:
aws route53 change-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  --change-batch file://dns-validation.json

# Wait for validation (can take up to 30 minutes)
aws acm wait certificate-validated \
  --certificate-arn $CERT_ARN \
  --region $AWS_REGION
```

### 5. Store Secrets in AWS Secrets Manager

```bash
# Create secret for OpenOps
aws secretsmanager create-secret \
  --name openops/production/env \
  --description "OpenOps production environment secrets" \
  --secret-string "{
    \"OPS_ENCRYPTION_KEY\": \"$(openssl rand -hex 16)\",
    \"OPS_JWT_SECRET\": \"$(openssl rand -hex 32)\",
    \"OPS_POSTGRES_PASSWORD\": \"$DB_PASSWORD\",
    \"OPS_OPENOPS_ADMIN_PASSWORD\": \"$(openssl rand -base64 24)\",
    \"OPS_ANALYTICS_ADMIN_PASSWORD\": \"$(openssl rand -base64 24)\",
    \"ANALYTICS_POWERUSER_PASSWORD\": \"$(openssl rand -base64 24)\"
  }" \
  --region $AWS_REGION

# Optional: Install External Secrets Operator to sync to Kubernetes
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace

# Create SecretStore
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: openops
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
EOF

# Create ExternalSecret
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: openops-env
  namespace: openops
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: openops-env
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: openops/production/env
EOF
```

---

## Prepare Helm Configuration

### 1. Create Kubernetes Namespace

```bash
kubectl create namespace openops

# Label namespace for monitoring/security policies
kubectl label namespace openops \
  environment=production \
  team=platform \
  app=openops
```

### 2. Create Storage Class for gp3

```bash
# Create gp3 StorageClass with optimal settings
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

# Verify
kubectl get storageclass
```

### 3. Create Values Override File

Create `values.aws-production.yaml`:

```yaml
# values.aws-production.yaml
global:
  version: "0.6.14"
  publicUrl: "https://openops.example.com"
  
  # Allow cross-AZ pod distribution
  topologySpreadConstraints:
    enabled: true
    maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
  
  # Enable pod anti-affinity for HA
  affinity:
    enabled: true

image:
  repository: public.ecr.aws/openops
  pullPolicy: IfNotPresent

openopsEnv:
  OPS_ENVIRONMENT_NAME: "production"
  OPS_LOG_LEVEL: warn
  OPS_LOG_PRETTY: "false"
  
  # Database - AWS RDS
  OPS_DB_TYPE: POSTGRES
  OPS_POSTGRES_DATABASE: openops
  OPS_POSTGRES_HOST: "openops-production-db.xxxxx.us-east-1.rds.amazonaws.com"
  OPS_POSTGRES_PORT: "5432"
  OPS_POSTGRES_USERNAME: openops_admin
  # OPS_POSTGRES_PASSWORD: set via secretEnv or AWS Secrets Manager
  
  # Tables database
  OPS_OPENOPS_TABLES_DATABASE_NAME: tables
  
  # Queue - AWS ElastiCache Redis
  OPS_QUEUE_MODE: REDIS
  OPS_REDIS_HOST: "openops-production-redis.xxxxx.cache.amazonaws.com"
  OPS_REDIS_PORT: "6379"
  # If using auth token:
  # OPS_REDIS_PASSWORD: set via secretEnv
  
  # AWS-specific settings
  OPS_AWS_ENABLE_IMPLICIT_ROLE: "true"
  
  # Optional: S3 for file storage
  # OPS_S3_BUCKET: "openops-production-storage-123456789012"
  # OPS_AWS_REGION: "us-east-1"
  
  # Telemetry
  OPS_TELEMETRY_MODE: COLLECTOR

# Secret management - using External Secrets or manual creation
secretEnv:
  create: false  # Using External Secrets Operator
  existingSecret: openops-env
  immutable: true

# Service accounts with IAM roles (IRSA)
serviceAccount:
  app:
    create: true
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/openops-app-role"
  engine:
    create: true
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/openops-engine-role"
  tables:
    create: true
  analytics:
    create: true
  nginx:
    create: true

# Application scaling
app:
  replicas: 3
  resources:
    requests:
      memory: "2Gi"
      cpu: "1000m"
    limits:
      memory: "4Gi"
      cpu: "2000m"

engine:
  replicas: 3
  resources:
    requests:
      memory: "1Gi"
      cpu: "500m"
    limits:
      memory: "2Gi"
      cpu: "1000m"

tables:
  replicas: 2
  resources:
    requests:
      memory: "1Gi"
      cpu: "500m"
    limits:
      memory: "2Gi"
      cpu: "1000m"
  storage:
    storageClass: "gp3"
    size: 50Gi
    annotations:
      snapshot.storage.kubernetes.io/enabled: "true"

analytics:
  replicas: 2
  resources:
    requests:
      memory: "2Gi"
      cpu: "1000m"
    limits:
      memory: "4Gi"
      cpu: "2000m"

# Disable bundled databases (using RDS and ElastiCache)
postgres:
  replicas: 0

redis:
  replicas: 0

# Nginx with NLB
nginx:
  replicas: 2
  resources:
    requests:
      memory: "256Mi"
      cpu: "200m"
    limits:
      memory: "512Mi"
      cpu: "400m"
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
      service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
      service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"
      # Optional: Enable HTTPS at NLB with ACM certificate
      # service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "arn:aws:acm:us-east-1:123456789012:certificate/xxxxx"
      # service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
      # Internal LB (if not exposing to internet):
      # service.beta.kubernetes.io/aws-load-balancer-internal: "true"

# Pod Disruption Budgets for HA
pdb:
  enabled: true
  app:
    enabled: true
    minAvailable: 2
  engine:
    enabled: true
    minAvailable: 2
  nginx:
    enabled: true
    minAvailable: 1
  analytics:
    enabled: true
    minAvailable: 1
  tables:
    enabled: true
    minAvailable: 1

# Horizontal Pod Autoscaling
hpa:
  enabled: true
  app:
    enabled: true
    minReplicas: 3
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70
    targetMemoryUtilizationPercentage: 80
  engine:
    enabled: true
    minReplicas: 3
    maxReplicas: 8
    targetCPUUtilizationPercentage: 70
  analytics:
    enabled: true
    minReplicas: 2
    maxReplicas: 5
    targetCPUUtilizationPercentage: 70
  nginx:
    enabled: true
    minReplicas: 2
    maxReplicas: 6
    targetCPUUtilizationPercentage: 70

# Network policies for security
networkPolicy:
  enabled: true
  allowExternal: true

# Resource limits
limitRange:
  enabled: true
  limits:
    - type: Container
      default:
        cpu: "1000m"
        memory: "2Gi"
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
      max:
        cpu: "4000m"
        memory: "8Gi"

# Monitoring
serviceMonitor:
  enabled: true  # Requires Prometheus Operator
  interval: 30s
  additionalLabels:
    release: prometheus
```

### 4. Create Secrets Manually (if not using External Secrets)

```bash
# Generate strong secrets
export OPS_ENCRYPTION_KEY=$(openssl rand -hex 16)
export OPS_JWT_SECRET=$(openssl rand -hex 32)
export OPS_ADMIN_PASSWORD=$(openssl rand -base64 24)
export ANALYTICS_ADMIN_PASSWORD=$(openssl rand -base64 24)
export ANALYTICS_POWERUSER_PASSWORD=$(openssl rand -base64 24)

# Save these securely! You'll need them to access the application

# Create Kubernetes secret
kubectl create secret generic openops-env -n openops \
  --from-literal=OPS_ENCRYPTION_KEY="$OPS_ENCRYPTION_KEY" \
  --from-literal=OPS_JWT_SECRET="$OPS_JWT_SECRET" \
  --from-literal=OPS_POSTGRES_PASSWORD="$DB_PASSWORD" \
  --from-literal=OPS_OPENOPS_ADMIN_EMAIL="admin@example.com" \
  --from-literal=OPS_OPENOPS_ADMIN_PASSWORD="$OPS_ADMIN_PASSWORD" \
  --from-literal=OPS_ANALYTICS_ADMIN_PASSWORD="$ANALYTICS_ADMIN_PASSWORD" \
  --from-literal=ANALYTICS_POWERUSER_PASSWORD="$ANALYTICS_POWERUSER_PASSWORD"

# Verify secret
kubectl get secret openops-env -n openops
```

---

## Deploy OpenOps

### 1. Clone the Helm Chart Repository

```bash
git clone https://github.com/your-org/helm-chart.git
cd helm-chart
```

### 2. Validate Configuration

```bash
# Lint the chart
helm lint ./chart -f values.aws-production.yaml

# Dry-run to preview manifests
helm upgrade --install openops ./chart \
  -n openops \
  -f chart/values.yaml \
  -f chart/values.production.yaml \
  -f values.aws-production.yaml \
  --dry-run --debug > /tmp/openops-preview.yaml

# Review the output
less /tmp/openops-preview.yaml
```

### 3. Install the Chart

```bash
# Install OpenOps
helm upgrade --install openops ./chart \
  -n openops \
  --create-namespace \
  -f chart/values.yaml \
  -f chart/values.production.yaml \
  -f values.aws-production.yaml \
  --wait \
  --timeout 10m

# Watch deployment progress
kubectl get pods -n openops -w

# Check deployment status
kubectl get all -n openops
```

### 4. Verify Deployment

```bash
# Check pod status
kubectl get pods -n openops

# Check logs
kubectl logs -n openops -l app=openops-app --tail=50
kubectl logs -n openops -l app=openops-engine --tail=50

# Run Helm tests
helm test openops -n openops

# Check services
kubectl get svc -n openops

# Get LoadBalancer endpoint
kubectl get svc nginx -n openops -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

---

## Post-Deployment Configuration

### 1. Configure DNS

```bash
# Get NLB DNS name
export NLB_DNS=$(kubectl get svc nginx -n openops -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "NLB Endpoint: $NLB_DNS"

# Create Route53 CNAME or ALIAS record
aws route53 change-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"openops.example.com\",
        \"Type\": \"A\",
        \"AliasTarget\": {
          \"HostedZoneId\": \"Z215JYRZR1TBD5\",
          \"DNSName\": \"$NLB_DNS\",
          \"EvaluateTargetHealth\": true
        }
      }
    }]
  }"

# Wait for DNS propagation (can take 5-60 minutes)
dig openops.example.com
```

### 2. Access OpenOps

```bash
# Get admin credentials
export ADMIN_EMAIL=$(kubectl get secret openops-env -n openops -o jsonpath='{.data.OPS_OPENOPS_ADMIN_EMAIL}' | base64 -d)
export ADMIN_PASSWORD=$(kubectl get secret openops-env -n openops -o jsonpath='{.data.OPS_OPENOPS_ADMIN_PASSWORD}' | base64 -d)

echo "Admin Email: $ADMIN_EMAIL"
echo "Admin Password: $ADMIN_PASSWORD"

# Access the application
echo "OpenOps URL: https://openops.example.com"
```

Open your browser and navigate to `https://openops.example.com`. Log in with the admin credentials.

### 3. Enable HTTPS (Optional - if not using NLB with ACM)

If you prefer using an Ingress Controller instead of NLB:

```bash
# Install nginx-ingress
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb"

# Install cert-manager
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  -n cert-manager \
  --create-namespace \
  --set installCRDs=true

# Create ClusterIssuer for Let's Encrypt
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

# Update values to enable Ingress
# Add to values.aws-production.yaml:
# ingress:
#   enabled: true
#   ingressClassName: nginx
#   annotations:
#     cert-manager.io/cluster-issuer: letsencrypt-prod
#   tlsConfig:
#     enabled: true

# Upgrade Helm release
helm upgrade openops ./chart \
  -n openops \
  -f chart/values.yaml \
  -f chart/values.production.yaml \
  -f values.aws-production.yaml
```

### 4. Configure Backups

```bash
# Install Velero for cluster backups
wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz
tar -xvf velero-v1.12.0-linux-amd64.tar.gz
sudo mv velero-v1.12.0-linux-amd64/velero /usr/local/bin/

# Create S3 bucket for backups
aws s3api create-bucket \
  --bucket openops-velero-backups-${AWS_ACCOUNT_ID} \
  --region $AWS_REGION

# Create IAM policy and user for Velero
# (See Velero AWS setup documentation)

# Install Velero
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket openops-velero-backups-${AWS_ACCOUNT_ID} \
  --backup-location-config region=$AWS_REGION \
  --snapshot-location-config region=$AWS_REGION \
  --secret-file ./credentials-velero

# Create backup schedule
velero schedule create openops-daily \
  --schedule="0 2 * * *" \
  --include-namespaces openops \
  --ttl 720h

# Test backup
velero backup create openops-test --include-namespaces openops
velero backup describe openops-test
```

---

## Monitoring and Operations

### 1. Install Prometheus and Grafana

```bash
# Add Prometheus community Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.adminPassword="$(openssl rand -base64 24)"

# Get Grafana password
kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d

# Port-forward to access Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Access Grafana at http://localhost:3000
```

### 2. CloudWatch Integration

```bash
# Install CloudWatch Container Insights
curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluentd-quickstart.yaml | \
  sed "s/{{cluster_name}}/openops-production/;s/{{region_name}}/$AWS_REGION/" | \
  kubectl apply -f -

# Verify
kubectl get pods -n amazon-cloudwatch
```

### 3. Set Up Alerts

Create CloudWatch alarms for critical metrics:

```bash
# CPU utilization alarm
aws cloudwatch put-metric-alarm \
  --alarm-name openops-high-cpu \
  --alarm-description "OpenOps high CPU usage" \
  --metric-name CPUUtilization \
  --namespace AWS/EKS \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2

# Database connection alarm
aws cloudwatch put-metric-alarm \
  --alarm-name openops-db-connections \
  --alarm-description "OpenOps high database connections" \
  --metric-name DatabaseConnections \
  --namespace AWS/RDS \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2
```

### 4. Log Aggregation

```bash
# Option 1: Ship logs to CloudWatch Logs (already configured with Container Insights)

# Option 2: Deploy EFK Stack (Elasticsearch, Fluentd, Kibana)
helm repo add elastic https://helm.elastic.co
helm install elasticsearch elastic/elasticsearch -n logging --create-namespace
helm install kibana elastic/kibana -n logging
kubectl apply -f https://raw.githubusercontent.com/fluent/fluentd-kubernetes-daemonset/master/fluentd-daemonset-elasticsearch.yaml
```

---

## Troubleshooting

### Common Issues

#### 1. Pods stuck in Pending state
```bash
# Check events
kubectl describe pod <pod-name> -n openops

# Common causes:
# - Insufficient resources: Scale node group or increase instance size
# - PVC binding issues: Check StorageClass and EBS CSI driver
# - Image pull errors: Verify ECR permissions or image repository
```

#### 2. Database connection errors
```bash
# Test database connectivity from a pod
kubectl run -it --rm debug --image=postgres:15 --restart=Never -n openops -- \
  psql -h <RDS_ENDPOINT> -U openops_admin -d openops

# Check security groups allow 5432 from EKS worker nodes
# Verify RDS endpoint in openopsEnv.OPS_POSTGRES_HOST
```

#### 3. Redis connection errors
```bash
# Test Redis connectivity
kubectl run -it --rm debug --image=redis:7 --restart=Never -n openops -- \
  redis-cli -h <REDIS_ENDPOINT> -p 6379 ping

# If using auth token, add: -a <AUTH_TOKEN>
# Check ElastiCache security groups
```

#### 4. LoadBalancer not getting external IP
```bash
# Check AWS Load Balancer Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Verify service account has correct IAM permissions
# Check VPC has available EIPs for NLB
```

#### 5. SSL/TLS certificate issues
```bash
# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Describe certificate
kubectl describe certificate -n openops

# Check DNS validation records
kubectl describe challenge -n openops
```

### Debugging Commands

```bash
# View all resources
kubectl get all -n openops

# Check pod logs
kubectl logs -n openops <pod-name> --previous  # Previous container logs
kubectl logs -n openops <pod-name> -c <container-name>  # Specific container

# Execute commands in pod
kubectl exec -it -n openops <pod-name> -- /bin/bash

# Check resource usage
kubectl top nodes
kubectl top pods -n openops

# Describe resources
kubectl describe pod -n openops <pod-name>
kubectl describe svc -n openops nginx

# Check events
kubectl get events -n openops --sort-by='.lastTimestamp'

# Port-forward for local debugging
kubectl port-forward -n openops svc/openops-app 8080:8080
```

### Rollback Deployment

```bash
# List Helm releases
helm list -n openops

# View release history
helm history openops -n openops

# Rollback to previous version
helm rollback openops -n openops

# Rollback to specific revision
helm rollback openops 2 -n openops
```

---

## Cost Optimization Tips

1. **Right-size instances**: Monitor actual resource usage and adjust instance types
2. **Use Spot Instances**: For non-critical workloads, use EC2 Spot for node groups
3. **Enable Cluster Autoscaler**: Automatically scale nodes based on demand
4. **Use gp3 instead of gp2**: gp3 offers better price/performance
5. **Reserved Instances**: For stable workloads, purchase RDS and EC2 RIs
6. **S3 lifecycle policies**: Archive old backups to Glacier
7. **Delete unused resources**: Remove old snapshots, AMIs, and EBS volumes
8. **Monitor costs**: Use AWS Cost Explorer and set up budgets/alerts

---

## Security Best Practices

1. **Enable EKS cluster logging**: Audit API calls and monitor for anomalies
2. **Use IAM roles for service accounts (IRSA)**: Avoid embedding AWS credentials
3. **Network policies**: Restrict pod-to-pod communication
4. **Encrypt everything**: EBS volumes, RDS, ElastiCache, S3 buckets
5. **Rotate secrets regularly**: Use AWS Secrets Manager rotation
6. **Scan images**: Use ECR image scanning or Trivy
7. **Limit public access**: Use private subnets and internal load balancers where possible
8. **MFA for admin access**: Require MFA for AWS Console and kubectl access
9. **Regular updates**: Keep EKS, node AMIs, and application versions current
10. **Pod Security Standards**: Enforce restricted security contexts

---

## Maintenance

### Upgrade EKS Cluster
```bash
# Upgrade control plane
eksctl upgrade cluster --name openops-production --version 1.30 --approve

# Upgrade node groups (rolling update)
eksctl upgrade nodegroup \
  --name openops-ng-1 \
  --cluster openops-production \
  --kubernetes-version 1.30

# Update add-ons
eksctl update addon \
  --name vpc-cni \
  --cluster openops-production
```

### Upgrade OpenOps
```bash
# Pull latest chart
git pull origin main

# Update values.aws-production.yaml with new version
# global.version: "0.7.0"

# Upgrade release
helm upgrade openops ./chart \
  -n openops \
  -f chart/values.yaml \
  -f chart/values.production.yaml \
  -f values.aws-production.yaml \
  --wait
```

---

## Support and Resources

- **Helm Chart Issues**: https://github.com/your-org/helm-chart/issues
- **AWS EKS Documentation**: https://docs.aws.amazon.com/eks/
- **Kubernetes Documentation**: https://kubernetes.io/docs/
- **OpenOps Documentation**: https://docs.openops.com

---

## Appendix

### A. Complete eksctl Cluster Configuration

See [eks-cluster.yaml](#option-1-using-eksctl-recommended) in the Provision EKS Cluster section.

### B. IAM Policy for IRSA

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::openops-production-storage-*",
        "arn:aws:s3:::openops-production-storage-*/*"
      ]
    }
  ]
}
```

### C. Resource Sizing Guidelines

| Component | Min (Dev) | Recommended (Prod) | High Traffic |
|-----------|-----------|-------------------|--------------|
| App | 1Gi/500m | 2Gi/1000m | 4Gi/2000m |
| Engine | 512Mi/250m | 1Gi/500m | 2Gi/1000m |
| Tables | 512Mi/250m | 1Gi/500m | 2Gi/1000m |
| Analytics | 1Gi/500m | 2Gi/1000m | 4Gi/2000m |
| Nginx | 128Mi/100m | 256Mi/200m | 512Mi/400m |

### D. Network Architecture Diagram

```
Internet
    │
    ▼
┌─────────────────┐
│   Route53 DNS   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Network Load   │
│   Balancer      │ (NLB)
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────┐
│         EKS Cluster                 │
│  ┌────────────┐  ┌────────────┐    │
│  │ Nginx Pods │  │  App Pods  │    │
│  └─────┬──────┘  └──────┬─────┘    │
│        │                │           │
│  ┌─────▼────────────────▼─────┐    │
│  │      Engine Pods           │    │
│  └────────┬──────┬────────────┘    │
│           │      │                  │
└───────────┼──────┼──────────────────┘
            │      │
     ┌──────▼──┐ ┌─▼───────┐
     │   RDS   │ │ElastiCache│
     │Postgres │ │  Redis   │
     └─────────┘ └──────────┘
```

---

**End of Deployment Guide**

For questions or issues, please open an issue in the GitHub repository or contact your platform team.
