# Deploying OpenOps to AWS EKS Fargate

This guide walks you through deploying the OpenOps Helm chart to a new Amazon EKS cluster running on AWS Fargate.

## Table of Contents
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [EKS Fargate Architecture](#eks-fargate-architecture)
- [Step 1: Create EKS Cluster with Fargate](#step-1-create-eks-cluster-with-fargate)
- [Step 2: Configure Fargate Profiles](#step-2-configure-fargate-profiles)
- [Step 3: Set Up Storage (EFS CSI Driver)](#step-3-set-up-storage-efs-csi-driver)
- [Step 4: Set Up External Dependencies](#step-4-set-up-external-dependencies)
- [Step 5: Configure IAM Roles (IRSA)](#step-5-configure-iam-roles-irsa)
- [Step 6: Prepare Helm Values](#step-6-prepare-helm-values)
- [Step 7: Deploy OpenOps](#step-7-deploy-openops)
- [Step 8: Configure Ingress and TLS](#step-8-configure-ingress-and-tls)
- [Step 9: Verify Deployment](#step-9-verify-deployment)
- [Monitoring and Operations](#monitoring-and-operations)
- [Troubleshooting](#troubleshooting)
- [Cost Optimization](#cost-optimization)

## Overview

AWS Fargate is a serverless compute engine for containers that removes the need to manage EC2 instances. When deploying OpenOps to EKS Fargate, you need to account for Fargate's unique characteristics:

- **No persistent local storage**: Fargate pods don't have access to EBS volumes directly; use Amazon EFS for shared storage
- **No DaemonSets**: Fargate doesn't support DaemonSets; use sidecar containers instead
- **Different resource allocation**: Fargate has specific CPU/memory combinations
- **Pod-level isolation**: Each pod runs in its own isolated compute environment

## Prerequisites

Before you begin, ensure you have the following:

### Required Tools
- **AWS CLI** (v2.x or later): `aws --version`
- **eksctl** (v0.150.0 or later): `eksctl version`
- **kubectl** (v1.28 or later): `kubectl version --client`
- **Helm** (v3.12 or later): `helm version`
- **aws-iam-authenticator**: Installed and configured

### AWS Account Requirements
- AWS account with appropriate permissions
- AWS CLI configured with credentials: `aws configure`
- VPC with public and private subnets (or let eksctl create one)
- Domain name for external access (optional but recommended)

### IAM Permissions
Your AWS user/role needs permissions to:
- Create and manage EKS clusters
- Create IAM roles and policies
- Create and manage VPCs, subnets, security groups
- Create RDS databases and ElastiCache clusters
- Create EFS file systems
- Create Application Load Balancers

## EKS Fargate Architecture

The recommended architecture for OpenOps on EKS Fargate:

```
┌─────────────────────────────────────────────────────────────┐
│                        Internet/Users                        │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│              AWS Application Load Balancer                   │
│              (via AWS Load Balancer Controller)              │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    EKS Fargate Cluster                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ Nginx Pods   │  │  App Pods    │  │ Engine Pods  │      │
│  │ (2 replicas) │  │ (3 replicas) │  │ (3 replicas) │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│  ┌──────────────┐  ┌──────────────┐                         │
│  │ Tables Pods  │  │Analytics Pods│                         │
│  │ (2 replicas) │  │ (2 replicas) │                         │
│  └──────┬───────┘  └──────┬───────┘                         │
└─────────┼──────────────────┼───────────────────────────────┘
          │                  │
          │ EFS Mount        │
          ▼                  │
┌─────────────────┐          │
│  Amazon EFS     │          │
│  (Tables data)  │          │
└─────────────────┘          │
                             │
          ┌──────────────────┴──────────────────┐
          ▼                                     ▼
┌─────────────────┐                   ┌─────────────────┐
│  Amazon RDS     │                   │ Amazon          │
│  PostgreSQL     │                   │ ElastiCache     │
│  (Multi-AZ)     │                   │ Redis           │
└─────────────────┘                   └─────────────────┘
```

**Key Design Decisions:**
- **Stateless components** (app, engine, nginx, analytics) run on Fargate without modifications
- **Tables** requires persistent storage, uses Amazon EFS via EFS CSI driver
- **PostgreSQL and Redis** use managed services (RDS and ElastiCache) instead of StatefulSets
- **Ingress** uses AWS Load Balancer Controller with Application Load Balancer

## Step 1: Create EKS Cluster with Fargate

### Option A: Using eksctl (Recommended)

Create a cluster configuration file `eksctl-fargate-config.yaml`:

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: openops-fargate
  region: us-east-1
  version: "1.31"

# IAM configuration for IRSA (IAM Roles for Service Accounts)
iam:
  withOIDC: true

# VPC configuration
vpc:
  cidr: 10.0.0.0/16
  nat:
    gateway: HighlyAvailable

# Fargate profiles
fargateProfiles:
  - name: openops-workloads
    selectors:
      - namespace: openops
        labels:
          fargate: enabled
      - namespace: openops
  - name: kube-system
    selectors:
      - namespace: kube-system

# Add-ons
addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest

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
eksctl create cluster -f eksctl-fargate-config.yaml
```

This takes approximately 15-20 minutes.

### Option B: Using AWS Console

1. Navigate to **EKS** in AWS Console
2. Click **Create cluster**
3. Configure cluster:
   - **Name**: openops-fargate
   - **Kubernetes version**: 1.31
   - **Cluster service role**: Create new or select existing
4. Configure networking:
   - **VPC**: Create new or select existing
   - **Subnets**: Select at least 2 private subnets in different AZs
   - **Security groups**: Default is fine
   - **Cluster endpoint access**: Public and private
5. Configure logging (optional but recommended)
6. Review and create

### Verify Cluster Creation

```bash
# Update kubeconfig
aws eks update-kubeconfig --region us-east-1 --name openops-fargate

# Verify cluster access
kubectl get svc
kubectl get nodes  # Will be empty until pods are scheduled

# Verify Fargate profiles
eksctl get fargateprofile --cluster openops-fargate --region us-east-1
```

## Step 2: Configure Fargate Profiles

Fargate profiles determine which pods run on Fargate. If you didn't create them during cluster creation, create them now:

```bash
# Profile for OpenOps workloads
eksctl create fargateprofile \
  --cluster openops-fargate \
  --region us-east-1 \
  --name openops-workloads \
  --namespace openops

# Profile for system components
eksctl create fargateprofile \
  --cluster openops-fargate \
  --region us-east-1 \
  --name kube-system \
  --namespace kube-system
```

### Patch CoreDNS for Fargate

CoreDNS needs to be patched to run on Fargate:

```bash
kubectl patch deployment coredns \
  -n kube-system \
  --type json \
  -p='[{"op": "remove", "path": "/spec/template/metadata/annotations/eks.amazonaws.com~1compute-type"}]'

# Restart CoreDNS
kubectl rollout restart -n kube-system deployment coredns
```

### Verify Fargate Nodes

After pods are scheduled, you'll see Fargate nodes:

```bash
kubectl get nodes
# Each node represents a Fargate worker for a pod
```

## Step 3: Set Up Storage (EFS CSI Driver)

Fargate pods cannot use EBS volumes directly. Use Amazon EFS for persistent storage needed by the Tables component.

### Create IAM Policy for EFS CSI Driver

```bash
# Download the IAM policy document
curl -o iam-policy-efs.json https://raw.githubusercontent.com/kubernetes-sigs/aws-efs-csi-driver/master/docs/iam-policy-example.json

# Create the IAM policy
aws iam create-policy \
  --policy-name AmazonEKS_EFS_CSI_Driver_Policy \
  --policy-document file://iam-policy-efs.json

# Note the Policy ARN from the output
```

### Create IAM Role for EFS CSI Driver (IRSA)

```bash
# Get your AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create IRSA for EFS CSI driver
eksctl create iamserviceaccount \
  --cluster openops-fargate \
  --region us-east-1 \
  --namespace kube-system \
  --name efs-csi-controller-sa \
  --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AmazonEKS_EFS_CSI_Driver_Policy \
  --approve
```

### Install EFS CSI Driver

```bash
# Add the EFS CSI driver Helm repository
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm repo update

# Install the EFS CSI driver
helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=efs-csi-controller-sa
```

### Create Amazon EFS File System

```bash
# Get VPC ID
VPC_ID=$(aws eks describe-cluster \
  --name openops-fargate \
  --region us-east-1 \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

# Create security group for EFS
MOUNT_TARGET_GROUP_ID=$(aws ec2 create-security-group \
  --group-name openops-efs-sg \
  --description "Security group for OpenOps EFS mount targets" \
  --vpc-id $VPC_ID \
  --output text)

# Allow NFS traffic from VPC CIDR
aws ec2 authorize-security-group-ingress \
  --group-id $MOUNT_TARGET_GROUP_ID \
  --protocol tcp \
  --port 2049 \
  --cidr 10.0.0.0/16

# Create EFS file system
FILE_SYSTEM_ID=$(aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags Key=Name,Value=openops-tables-data \
  --region us-east-1 \
  --query 'FileSystemId' \
  --output text)

echo "EFS File System ID: $FILE_SYSTEM_ID"

# Wait for file system to become available
aws efs describe-file-systems \
  --file-system-id $FILE_SYSTEM_ID \
  --region us-east-1 \
  --query 'FileSystems[0].LifeCycleState' \
  --output text

# Get subnet IDs (where EKS cluster is deployed)
SUBNET_IDS=$(aws eks describe-cluster \
  --name openops-fargate \
  --region us-east-1 \
  --query "cluster.resourcesVpcConfig.subnetIds" \
  --output text)

# Create mount targets in each subnet
for SUBNET_ID in $SUBNET_IDS; do
  echo "Creating mount target in subnet: $SUBNET_ID"
  aws efs create-mount-target \
    --file-system-id $FILE_SYSTEM_ID \
    --subnet-id $SUBNET_ID \
    --security-groups $MOUNT_TARGET_GROUP_ID \
    --region us-east-1
done
```

### Create StorageClass for EFS

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${FILE_SYSTEM_ID}
  directoryPerms: "700"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
  basePath: "/openops"
EOF
```

## Step 4: Set Up External Dependencies

Fargate doesn't support StatefulSets with local storage reliably. Use managed AWS services for PostgreSQL and Redis.

### Create RDS PostgreSQL Database

```bash
# Get VPC security group ID for EKS cluster
CLUSTER_SG=$(aws eks describe-cluster \
  --name openops-fargate \
  --region us-east-1 \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" \
  --output text)

# Create security group for RDS
RDS_SG=$(aws ec2 create-security-group \
  --group-name openops-rds-sg \
  --description "Security group for OpenOps RDS" \
  --vpc-id $VPC_ID \
  --output text)

# Allow PostgreSQL traffic from EKS cluster security group
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG \
  --protocol tcp \
  --port 5432 \
  --source-group $CLUSTER_SG

# Get private subnet IDs for RDS
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*Private*" \
  --query "Subnets[*].SubnetId" \
  --output text)

# Create DB subnet group
aws rds create-db-subnet-group \
  --db-subnet-group-name openops-db-subnet-group \
  --db-subnet-group-description "Subnet group for OpenOps RDS" \
  --subnet-ids $PRIVATE_SUBNETS \
  --region us-east-1

# Generate strong password
DB_PASSWORD=$(openssl rand -base64 32)
echo "PostgreSQL Password: $DB_PASSWORD"
echo "IMPORTANT: Save this password securely!"

# Create RDS PostgreSQL instance (Multi-AZ for production)
aws rds create-db-instance \
  --db-instance-identifier openops-postgres \
  --db-instance-class db.t4g.large \
  --engine postgres \
  --engine-version 16.1 \
  --master-username openops_admin \
  --master-user-password "$DB_PASSWORD" \
  --allocated-storage 100 \
  --storage-type gp3 \
  --storage-encrypted \
  --multi-az \
  --db-subnet-group-name openops-db-subnet-group \
  --vpc-security-group-ids $RDS_SG \
  --backup-retention-period 7 \
  --preferred-backup-window "03:00-04:00" \
  --preferred-maintenance-window "mon:04:00-mon:05:00" \
  --enable-cloudwatch-logs-exports '["postgresql","upgrade"]' \
  --deletion-protection \
  --region us-east-1

# Wait for RDS to become available (takes 10-15 minutes)
aws rds wait db-instance-available \
  --db-instance-identifier openops-postgres \
  --region us-east-1

# Get RDS endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier openops-postgres \
  --region us-east-1 \
  --query "DBInstances[0].Endpoint.Address" \
  --output text)

echo "RDS Endpoint: $RDS_ENDPOINT"

# Connect to RDS and create databases
# Install PostgreSQL client if not already installed
# sudo yum install postgresql15  # Amazon Linux 2
# sudo apt-get install postgresql-client  # Ubuntu/Debian

PGPASSWORD=$DB_PASSWORD psql \
  -h $RDS_ENDPOINT \
  -U openops_admin \
  -d postgres \
  -c "CREATE DATABASE openops;"

PGPASSWORD=$DB_PASSWORD psql \
  -h $RDS_ENDPOINT \
  -U openops_admin \
  -d postgres \
  -c "CREATE DATABASE tables;"

PGPASSWORD=$DB_PASSWORD psql \
  -h $RDS_ENDPOINT \
  -U openops_admin \
  -d postgres \
  -c "CREATE DATABASE analytics;"
```

### Create ElastiCache Redis Cluster

```bash
# Create security group for ElastiCache
REDIS_SG=$(aws ec2 create-security-group \
  --group-name openops-redis-sg \
  --description "Security group for OpenOps Redis" \
  --vpc-id $VPC_ID \
  --output text)

# Allow Redis traffic from EKS cluster security group
aws ec2 authorize-security-group-ingress \
  --group-id $REDIS_SG \
  --protocol tcp \
  --port 6379 \
  --source-group $CLUSTER_SG

# Create cache subnet group
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name openops-redis-subnet-group \
  --cache-subnet-group-description "Subnet group for OpenOps Redis" \
  --subnet-ids $PRIVATE_SUBNETS \
  --region us-east-1

# Create Redis replication group (cluster mode disabled, Multi-AZ)
aws elasticache create-replication-group \
  --replication-group-id openops-redis \
  --replication-group-description "OpenOps Redis cluster" \
  --engine redis \
  --engine-version 7.1 \
  --cache-node-type cache.t4g.medium \
  --num-cache-clusters 2 \
  --automatic-failover-enabled \
  --multi-az-enabled \
  --cache-subnet-group-name openops-redis-subnet-group \
  --security-group-ids $REDIS_SG \
  --at-rest-encryption-enabled \
  --transit-encryption-enabled \
  --auth-token "$(openssl rand -base64 32 | tr -d '/@\"' | head -c 32)" \
  --snapshot-retention-limit 5 \
  --snapshot-window "03:00-05:00" \
  --preferred-maintenance-window "mon:05:00-mon:07:00" \
  --region us-east-1

# Wait for Redis to become available (takes 10-15 minutes)
aws elasticache wait replication-group-available \
  --replication-group-id openops-redis \
  --region us-east-1

# Get Redis endpoint
REDIS_ENDPOINT=$(aws elasticache describe-replication-groups \
  --replication-group-id openops-redis \
  --region us-east-1 \
  --query "ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address" \
  --output text)

echo "Redis Endpoint: $REDIS_ENDPOINT"
```

### Store Secrets in AWS Secrets Manager

```bash
# Store database password
aws secretsmanager create-secret \
  --name openops/postgres/password \
  --description "OpenOps PostgreSQL password" \
  --secret-string "$DB_PASSWORD" \
  --region us-east-1

# Generate and store application secrets
aws secretsmanager create-secret \
  --name openops/encryption-key \
  --description "OpenOps encryption key" \
  --secret-string "$(openssl rand -hex 32)" \
  --region us-east-1

aws secretsmanager create-secret \
  --name openops/jwt-secret \
  --description "OpenOps JWT secret" \
  --secret-string "$(openssl rand -hex 32)" \
  --region us-east-1

aws secretsmanager create-secret \
  --name openops/admin-password \
  --description "OpenOps admin password" \
  --secret-string "$(openssl rand -base64 24)" \
  --region us-east-1

aws secretsmanager create-secret \
  --name openops/analytics-admin-password \
  --description "OpenOps analytics admin password" \
  --secret-string "$(openssl rand -base64 24)" \
  --region us-east-1

aws secretsmanager create-secret \
  --name openops/analytics-poweruser-password \
  --description "OpenOps analytics poweruser password" \
  --secret-string "$(openssl rand -base64 24)" \
  --region us-east-1
```

## Step 5: Configure IAM Roles (IRSA)

Use IAM Roles for Service Accounts (IRSA) to grant pods AWS permissions without hardcoded credentials.

### Create IAM Policy for OpenOps

```bash
# Create IAM policy for OpenOps app (example: S3, SES, etc.)
cat > openops-app-policy.json <<EOF
{
  "Version": "2012-01-17",
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
        "arn:aws:s3:::openops-*",
        "arn:aws:s3:::openops-*/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ses:SendEmail",
        "ses:SendRawEmail"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:us-east-1:${AWS_ACCOUNT_ID}:secret:openops/*"
      ]
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name OpenOpsAppPolicy \
  --policy-document file://openops-app-policy.json

# Create IRSA for app
eksctl create iamserviceaccount \
  --cluster openops-fargate \
  --region us-east-1 \
  --namespace openops \
  --name openops-app \
  --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/OpenOpsAppPolicy \
  --approve

# Create IRSA for engine (similar permissions)
eksctl create iamserviceaccount \
  --cluster openops-fargate \
  --region us-east-1 \
  --namespace openops \
  --name openops-engine \
  --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/OpenOpsAppPolicy \
  --approve
```

## Step 6: Prepare Helm Values

Create a values file for Fargate deployment `values.eks-fargate.yaml`:

```yaml
# EKS Fargate-specific configuration for OpenOps
global:
  version: "0.6.14"
  publicUrl: "https://openops.example.com"  # Change to your domain

  # Fargate-specific: disable node selectors and tolerations
  nodeSelector: {}
  tolerations: []

  # Security context (Fargate supports this)
  securityContext:
    enabled: true
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault

  # Topology spread constraints work on Fargate
  topologySpreadConstraints:
    enabled: true
    maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway

image:
  repository: public.ecr.aws/openops
  pullPolicy: IfNotPresent

# Environment configuration
openopsEnv:
  OPS_ENVIRONMENT_NAME: "production-fargate"
  OPS_LOG_LEVEL: warn
  OPS_LOG_PRETTY: "false"

  # External RDS PostgreSQL
  OPS_DB_TYPE: POSTGRES
  OPS_POSTGRES_DATABASE: openops
  OPS_POSTGRES_HOST: "REPLACE_WITH_RDS_ENDPOINT"  # Replace with actual RDS endpoint
  OPS_POSTGRES_PORT: "5432"
  OPS_POSTGRES_USERNAME: openops_admin
  # Password will be set via secret

  # Tables database
  OPS_OPENOPS_TABLES_DATABASE_NAME: tables

  # External ElastiCache Redis
  OPS_QUEUE_MODE: REDIS
  OPS_REDIS_HOST: "REPLACE_WITH_REDIS_ENDPOINT"  # Replace with actual Redis endpoint
  OPS_REDIS_PORT: "6379"

  # AWS-specific settings
  OPS_AWS_ENABLE_IMPLICIT_ROLE: "true"

  # Telemetry
  OPS_TELEMETRY_MODE: COLLECTOR
  OPS_TELEMETRY_COLLECTOR_URL: https://telemetry.openops.com/save

# Secret management - create manually or use External Secrets Operator
secretEnv:
  create: true
  # For production, use existingSecret with External Secrets Operator:
  # create: false
  # existingSecret: openops-env

# Application - stateless, Fargate-compatible
app:
  replicas: 3
  resources:
    requests:
      memory: "2Gi"
      cpu: "1000m"
    limits:
      memory: "4Gi"
      cpu: "2000m"
  serviceAccount:
    create: false  # Created via IRSA in Step 5
    name: "openops-app"
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::REPLACE_ACCOUNT_ID:role/eksctl-openops-fargate-addon-iamserviceacc-Role1-XXXXX"
  podDisruptionBudget:
    enabled: true
    minAvailable: 2

# Engine - stateless, Fargate-compatible
engine:
  replicas: 3
  resources:
    requests:
      memory: "1Gi"
      cpu: "500m"
    limits:
      memory: "2Gi"
      cpu: "1000m"
  serviceAccount:
    create: false  # Created via IRSA in Step 5
    name: "openops-engine"
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::REPLACE_ACCOUNT_ID:role/eksctl-openops-fargate-addon-iamserviceacc-Role2-XXXXX"
  podDisruptionBudget:
    enabled: true
    minAvailable: 2

# Tables - requires persistent storage via EFS
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
    storageClass: "efs-sc"  # EFS StorageClass created in Step 3
    size: 50Gi
  serviceAccount:
    create: true
    annotations: {}
  podDisruptionBudget:
    enabled: true
    minAvailable: 1

# Analytics - stateless, Fargate-compatible
analytics:
  replicas: 2
  resources:
    requests:
      memory: "2Gi"
      cpu: "1000m"
    limits:
      memory: "4Gi"
      cpu: "2000m"
  serviceAccount:
    create: true
    annotations: {}
  podDisruptionBudget:
    enabled: true
    minAvailable: 1

# Nginx - stateless, Fargate-compatible
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
    type: LoadBalancer  # Will use AWS Load Balancer Controller
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "external"
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
      service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
      # Optional: Use ACM certificate for HTTPS
      # service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "arn:aws:acm:us-east-1:ACCOUNT:certificate/CERT_ID"
      # service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
  serviceAccount:
    create: true
    annotations: {}
  podDisruptionBudget:
    enabled: true
    minAvailable: 1

# Disable in-cluster PostgreSQL - using RDS
postgres:
  replicas: 0

# Disable in-cluster Redis - using ElastiCache
redis:
  replicas: 0

# Network Policy (works on Fargate)
networkPolicy:
  enabled: true

# Service Monitor for Prometheus (optional)
serviceMonitor:
  enabled: false  # Enable if you have Prometheus Operator
```

### Create Kubernetes Secrets

Retrieve secrets from AWS Secrets Manager and create Kubernetes secret:

```bash
# Create namespace
kubectl create namespace openops

# Retrieve secrets from AWS Secrets Manager
DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id openops/postgres/password --query SecretString --output text)
ENCRYPTION_KEY=$(aws secretsmanager get-secret-value --secret-id openops/encryption-key --query SecretString --output text)
JWT_SECRET=$(aws secretsmanager get-secret-value --secret-id openops/jwt-secret --query SecretString --output text)
ADMIN_PASSWORD=$(aws secretsmanager get-secret-value --secret-id openops/admin-password --query SecretString --output text)
ANALYTICS_ADMIN_PASSWORD=$(aws secretsmanager get-secret-value --secret-id openops/analytics-admin-password --query SecretString --output text)
ANALYTICS_POWERUSER_PASSWORD=$(aws secretsmanager get-secret-value --secret-id openops/analytics-poweruser-password --query SecretString --output text)

# Create Kubernetes secret
kubectl create secret generic openops-env -n openops \
  --from-literal=OPS_POSTGRES_PASSWORD="$DB_PASSWORD" \
  --from-literal=OPS_ENCRYPTION_KEY="$ENCRYPTION_KEY" \
  --from-literal=OPS_JWT_SECRET="$JWT_SECRET" \
  --from-literal=OPS_OPENOPS_ADMIN_EMAIL="admin@example.com" \
  --from-literal=OPS_OPENOPS_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  --from-literal=OPS_ANALYTICS_ADMIN_PASSWORD="$ANALYTICS_ADMIN_PASSWORD" \
  --from-literal=ANALYTICS_POWERUSER_PASSWORD="$ANALYTICS_POWERUSER_PASSWORD"
```

Alternatively, use **External Secrets Operator** (recommended for production):

```bash
# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace

# Create IAM policy for External Secrets Operator
cat > external-secrets-policy.json <<EOF
{
  "Version": "2012-01-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:us-east-1:${AWS_ACCOUNT_ID}:secret:openops/*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name ExternalSecretsPolicy \
  --policy-document file://external-secrets-policy.json

# Create IRSA for External Secrets
eksctl create iamserviceaccount \
  --cluster openops-fargate \
  --region us-east-1 \
  --namespace external-secrets-system \
  --name external-secrets \
  --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ExternalSecretsPolicy \
  --approve

# Create SecretStore
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secretsmanager
  namespace: openops
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets-system
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
    name: aws-secretsmanager
    kind: SecretStore
  target:
    name: openops-env
    creationPolicy: Owner
  data:
    - secretKey: OPS_POSTGRES_PASSWORD
      remoteRef:
        key: openops/postgres/password
    - secretKey: OPS_ENCRYPTION_KEY
      remoteRef:
        key: openops/encryption-key
    - secretKey: OPS_JWT_SECRET
      remoteRef:
        key: openops/jwt-secret
    - secretKey: OPS_OPENOPS_ADMIN_PASSWORD
      remoteRef:
        key: openops/admin-password
    - secretKey: OPS_ANALYTICS_ADMIN_PASSWORD
      remoteRef:
        key: openops/analytics-admin-password
    - secretKey: ANALYTICS_POWERUSER_PASSWORD
      remoteRef:
        key: openops/analytics-poweruser-password
  dataFrom:
    - extract:
        key: openops/admin-email
EOF
```

## Step 7: Deploy OpenOps

Now deploy the OpenOps Helm chart:

```bash
# Update values file with actual endpoints
sed -i "s/REPLACE_WITH_RDS_ENDPOINT/${RDS_ENDPOINT}/g" values.eks-fargate.yaml
sed -i "s/REPLACE_WITH_REDIS_ENDPOINT/${REDIS_ENDPOINT}/g" values.eks-fargate.yaml

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i "s/REPLACE_ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" values.eks-fargate.yaml

# Deploy OpenOps
helm upgrade --install openops ./chart \
  -n openops \
  --create-namespace \
  -f chart/values.yaml \
  -f values.eks-fargate.yaml

# Watch deployment progress
kubectl get pods -n openops -w

# Check pod status
kubectl get pods -n openops

# Check Fargate nodes (one per pod)
kubectl get nodes
```

### Verify Deployment

```bash
# Check all resources
kubectl get all -n openops

# Check pod logs
kubectl logs -n openops -l app.kubernetes.io/component=app --tail=50
kubectl logs -n openops -l app.kubernetes.io/component=engine --tail=50
kubectl logs -n openops -l app.kubernetes.io/component=tables --tail=50

# Verify persistent storage (Tables)
kubectl get pvc -n openops
kubectl describe pvc -n openops

# Run Helm tests
helm test openops -n openops
```

## Step 8: Configure Ingress and TLS

### Option A: Using AWS Load Balancer Controller (Recommended)

Install the AWS Load Balancer Controller to manage Application Load Balancers:

```bash
# Create IAM policy for AWS Load Balancer Controller
curl -o iam-policy-alb.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy-alb.json

# Create IRSA for AWS Load Balancer Controller
eksctl create iamserviceaccount \
  --cluster openops-fargate \
  --region us-east-1 \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# Install AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=openops-fargate \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId=$VPC_ID

# Verify controller is running
kubectl get deployment -n kube-system aws-load-balancer-controller
```

### Configure Ingress with ALB

Create an ACM certificate for your domain:

```bash
# Request ACM certificate (requires domain validation)
CERT_ARN=$(aws acm request-certificate \
  --domain-name openops.example.com \
  --validation-method DNS \
  --region us-east-1 \
  --query CertificateArn \
  --output text)

echo "Certificate ARN: $CERT_ARN"
echo "Complete DNS validation in ACM console or Route 53"

# Wait for certificate validation
aws acm wait certificate-validated \
  --certificate-arn $CERT_ARN \
  --region us-east-1
```

Update values file to enable Ingress:

```yaml
# Add to values.eks-fargate.yaml
ingress:
  enabled: true
  ingressClassName: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: "REPLACE_WITH_CERT_ARN"
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
  hosts:
    - paths:
        - path: /
          pathType: Prefix
          serviceName: nginx
          servicePort: 80
  tlsConfig:
    enabled: true

# Change nginx service to ClusterIP (ALB will handle external access)
nginx:
  service:
    type: ClusterIP
```

Apply the changes:

```bash
# Update certificate ARN
sed -i "s|REPLACE_WITH_CERT_ARN|${CERT_ARN}|g" values.eks-fargate.yaml

# Upgrade deployment
helm upgrade openops ./chart \
  -n openops \
  -f chart/values.yaml \
  -f values.eks-fargate.yaml

# Get ALB address
kubectl get ingress -n openops

# Create Route 53 record pointing to ALB
ALB_HOSTNAME=$(kubectl get ingress openops-ingress -n openops -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Create DNS record (if using Route 53)
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name example.com \
  --query "HostedZones[0].Id" \
  --output text | cut -d'/' -f3)

cat > change-batch.json <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "openops.example.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z35SXDOTRQ7X7K",
          "DNSName": "${ALB_HOSTNAME}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file://change-batch.json
```

## Step 9: Verify Deployment

```bash
# Check all pods are running
kubectl get pods -n openops

# Check ingress
kubectl get ingress -n openops

# Test connectivity
curl -I https://openops.example.com

# Access the application
open https://openops.example.com  # macOS
# or visit in browser
```

### Health Checks

```bash
# App health
kubectl exec -n openops -it $(kubectl get pod -n openops -l app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}') -- curl localhost:8080/health

# Engine health
kubectl exec -n openops -it $(kubectl get pod -n openops -l app.kubernetes.io/component=engine -o jsonpath='{.items[0].metadata.name}') -- curl localhost:8080/health

# Check RDS connectivity
kubectl run -n openops -i --tty --rm debug --image=postgres:16 --restart=Never -- psql -h $RDS_ENDPOINT -U openops_admin -d openops -c "SELECT version();"

# Check Redis connectivity
kubectl run -n openops -i --tty --rm debug --image=redis:7 --restart=Never -- redis-cli -h $REDIS_ENDPOINT ping
```

## Monitoring and Operations

### CloudWatch Container Insights

Enable Container Insights for EKS:

```bash
# Install CloudWatch agent
eksctl create addon \
  --cluster openops-fargate \
  --region us-east-1 \
  --name amazon-cloudwatch-observability

# Or manually install
ClusterName=openops-fargate
RegionName=us-east-1
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'

curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${RegionName}'/;s/{{http_server_toggle}}/"'${FluentBitHttpServer}'"/;s/{{http_server_port}}/"'${FluentBitHttpPort}'"/;s/{{read_from_head}}/"'${FluentBitReadFromHead}'"/;s/{{read_from_tail}}/"'${FluentBitReadFromTail}'"/' | kubectl apply -f -
```

### Prometheus and Grafana (Optional)

```bash
# Install kube-prometheus-stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false

# Enable ServiceMonitor in OpenOps
# Add to values.eks-fargate.yaml:
# serviceMonitor:
#   enabled: true
#   labels:
#     release: prometheus

# Upgrade OpenOps
helm upgrade openops ./chart -n openops -f chart/values.yaml -f values.eks-fargate.yaml

# Access Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

### Log Aggregation

```bash
# Logs are automatically sent to CloudWatch Logs
# View logs in CloudWatch Logs console under /aws/eks/openops-fargate/

# Or stream logs from CLI
aws logs tail /aws/eks/openops-fargate/application --follow --region us-east-1
```

## Troubleshooting

### Pods Stuck in Pending

Fargate pods can take 30-60 seconds to start (vs 1-5 seconds on EC2 nodes).

```bash
# Check pod events
kubectl describe pod -n openops <pod-name>

# Common issues:
# 1. Pod doesn't match Fargate profile selector
eksctl get fargateprofile --cluster openops-fargate --region us-east-1

# 2. Fargate profile not configured for namespace
eksctl create fargateprofile \
  --cluster openops-fargate \
  --region us-east-1 \
  --name openops-workloads \
  --namespace openops

# 3. Insufficient capacity (rare)
# Wait and retry, or create additional Fargate profiles
```

### EFS Mount Issues

```bash
# Check EFS mount targets are in available state
aws efs describe-mount-targets \
  --file-system-id $FILE_SYSTEM_ID \
  --region us-east-1

# Check security group allows NFS (port 2049)
aws ec2 describe-security-groups \
  --group-ids $MOUNT_TARGET_GROUP_ID \
  --region us-east-1

# Check PVC status
kubectl describe pvc -n openops

# Check EFS CSI driver logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-efs-csi-driver
```

### Database Connection Issues

```bash
# Verify RDS endpoint is reachable from pods
kubectl run -n openops -i --tty --rm debug --image=postgres:16 --restart=Never -- bash
# Inside pod:
apt-get update && apt-get install -y dnsutils netcat
nslookup $RDS_ENDPOINT
nc -zv $RDS_ENDPOINT 5432

# Check security group rules
aws ec2 describe-security-groups \
  --group-ids $RDS_SG \
  --region us-east-1

# Verify credentials
kubectl get secret openops-env -n openops -o jsonpath='{.data.OPS_POSTGRES_PASSWORD}' | base64 -d
```

### Service Account Issues (IRSA)

```bash
# Verify service account has correct annotation
kubectl get sa -n openops openops-app -o yaml

# Check IAM role trust policy
aws iam get-role \
  --role-name eksctl-openops-fargate-addon-iamserviceacc-Role1-XXXXX

# Test AWS credentials from pod
kubectl exec -n openops -it $(kubectl get pod -n openops -l app.kubernetes.io/component=app -o jsonpath='{.items[0].metadata.name}') -- env | grep AWS
```

### Load Balancer Issues

```bash
# Check AWS Load Balancer Controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check ingress status
kubectl describe ingress -n openops

# Check target group health in AWS console
# EC2 > Target Groups > openops-*
```

## Cost Optimization

### Right-Sizing Resources

Fargate pricing is based on vCPU and memory allocated. Review and adjust:

```bash
# Monitor actual resource usage
kubectl top pods -n openops

# Adjust requests/limits in values file based on actual usage
# Example: If app pods use 500Mi-1Gi, reduce from 2Gi request to 1Gi
```

### Fargate Spot (For Non-Critical Workloads)

Fargate Spot can save up to 70% for interruptible workloads:

```yaml
# Add capacity provider strategy to Fargate profile
# Note: This requires AWS API, not available via eksctl yet
# Use AWS Console or CloudFormation to create Fargate profile with Spot
```

### Use Savings Plans

AWS Compute Savings Plans can reduce Fargate costs by up to 52%:

```bash
# Purchase Compute Savings Plan in AWS Billing console
# Commitment: 1-year or 3-year
```

### Autoscaling

Enable HPA to scale down during off-peak:

```yaml
# Add to values.eks-fargate.yaml
app:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70

engine:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 8
    targetCPUUtilizationPercentage: 70
```

### Reduce External Dependencies Costs

- **RDS**: Use Reserved Instances for 1-3 year commitments (up to 60% savings)
- **ElastiCache**: Use Reserved Nodes for long-term workloads
- **EFS**: Enable Lifecycle Management to move infrequently accessed files to IA storage class

```bash
# Enable EFS Lifecycle Management
aws efs put-lifecycle-configuration \
  --file-system-id $FILE_SYSTEM_ID \
  --lifecycle-policies TransitionToIA=AFTER_30_DAYS \
  --region us-east-1
```

## Summary

You've successfully deployed OpenOps to AWS EKS Fargate! Here's what you've accomplished:

✅ Created an EKS cluster with Fargate profiles  
✅ Configured EFS for persistent storage (Tables component)  
✅ Set up external RDS PostgreSQL and ElastiCache Redis  
✅ Configured IAM Roles for Service Accounts (IRSA)  
✅ Deployed OpenOps with production-ready settings  
✅ Configured Ingress with AWS Load Balancer Controller and TLS  
✅ Set up monitoring with CloudWatch Container Insights  

### Next Steps

1. **Configure backups**: Set up automated RDS snapshots and EFS backups
2. **Set up CI/CD**: Integrate with GitHub Actions, GitLab CI, or AWS CodePipeline
3. **Configure monitoring alerts**: Set up CloudWatch alarms for critical metrics
4. **Implement disaster recovery**: Document and test DR procedures
5. **Security hardening**: Enable GuardDuty, Security Hub, and Config
6. **Cost monitoring**: Set up AWS Budgets and Cost Anomaly Detection

### Key Differences from EC2-Based Deployments

| Aspect | EC2 Nodes | Fargate |
|--------|-----------|---------|
| Node management | Manual | Fully managed |
| Pod startup time | 1-5 seconds | 30-60 seconds |
| Persistent storage | EBS + EFS | EFS only |
| StatefulSets | Supported with EBS | Use external services |
| DaemonSets | Supported | Not supported |
| Resource allocation | Flexible | Fixed CPU/memory ratios |
| Cost | Lower for high utilization | Lower for low utilization |
| Security | Shared kernel | Pod-level isolation |

For questions or issues, refer to the [main README](README.md) or open an issue in the repository.
