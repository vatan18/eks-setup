# LGTM Stack on Amazon EKS - Complete Setup Guide

Complete infrastructure-as-code solution for deploying the LGTM (Loki, Grafana, Tempo, Mimir) observability stack on Amazon EKS with Jenkins CI/CD pipelines.

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Directory Structure](#directory-structure)
- [Detailed Setup](#detailed-setup)
- [Operations](#operations)
- [Troubleshooting](#troubleshooting)
- [Cost Estimation](#cost-estimation)

---

## 🎯 Overview

This repository provides a complete, production-ready solution for deploying the LGTM observability stack on Amazon EKS using:

- **AWS CloudFormation** for infrastructure provisioning
- **Jenkins** for CI/CD automation
- **Helm** for Kubernetes application deployment
- **IRSA** (IAM Roles for Service Accounts) for secure AWS access
- **Node taints and tolerations** for workload isolation

### What is LGTM Stack?

- **Loki**: Log aggregation system
- **Grafana**: Visualization and dashboarding
- **Tempo**: Distributed tracing backend
- **Mimir**: Prometheus-compatible metrics backend

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS Cloud                            │
│                                                             │
│  ┌───────────────────────────────────────────────────┐    │
│  │                  EKS Cluster                       │    │
│  │                                                     │    │
│  │  ┌──────────────────┐  ┌──────────────────┐      │    │
│  │  │ General Nodes    │  │ Monitoring Nodes │      │    │
│  │  │                  │  │  (with taints)   │      │    │
│  │  │ - App workloads  │  │  - Loki          │      │    │
│  │  │ - Services       │  │  - Grafana       │      │    │
│  │  │                  │  │  - Tempo         │      │    │
│  │  │                  │  │  - Mimir         │      │    │
│  │  └──────────────────┘  │  - Alloy         │      │    │
│  │                         └──────────────────┘      │    │
│  │                                                     │    │
│  └─────────────────────────────────────────────────────┘    │
│                             │                               │
│                             │ IRSA                          │
│                             ▼                               │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              S3 Buckets (Storage)                   │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐         │    │
│  │  │   Loki   │  │  Tempo   │  │  Mimir   │         │    │
│  │  │  (Logs)  │  │ (Traces) │  │(Metrics) │         │    │
│  │  └──────────┘  └──────────┘  └──────────┘         │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Key Features

✅ **Production-Ready**: High availability, auto-scaling, monitoring
✅ **Secure**: IRSA for credential-free AWS access, encrypted storage
✅ **Isolated**: Dedicated nodes with taints for monitoring workloads
✅ **Automated**: Complete CI/CD with Jenkins pipelines
✅ **Cost-Optimized**: S3 lifecycle policies, right-sized instances
✅ **Observable**: Built-in monitoring and alerting

---

## 📦 Prerequisites

### Required Tools

```bash
# AWS CLI v2
aws --version  # Should be 2.x

# kubectl
kubectl version --client

# Helm 3
helm version

# jq (for scripts)
jq --version

# Git
git --version
```

### AWS Permissions

Your AWS user/role needs permissions for:
- EKS (cluster and node group management)
- EC2 (VPC, instances, security groups)
- IAM (roles, policies, OIDC provider)
- S3 (bucket creation and management)
- CloudFormation (stack operations)

### AWS Configuration

```bash
# Configure AWS credentials
aws configure

# Verify access
aws sts get-caller-identity
```

---

## 🚀 Quick Start

### 1. Clone the Repository

```bash
git clone <your-repo-url>
cd lgtm-eks-setup
```

### 2. Set Configuration

```bash
export AWS_REGION=us-east-1
export CLUSTER_NAME=my-eks-cluster
export ENVIRONMENT=prod
```

### 3. Deploy Infrastructure

```bash
# Make scripts executable
chmod +x scripts/*.sh

# Run automated deployment
./scripts/deploy-all.sh
```

This will:
- Create EKS cluster with VPC
- Deploy node groups (general and monitoring with taints)
- Create S3 buckets for storage
- Set up IRSA roles
- Install EBS CSI Driver
- Optionally install AWS Load Balancer Controller

**Duration**: ~30-40 minutes

### 4. Update Helm Values

The deployment script will output the IRSA role ARN and bucket names. Update your Helm values file:

```yaml
# helm-values/lgtm-prod-values.yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/ROLE_NAME

# Update S3 bucket names
tempo:
  storage:
    trace:
      s3:
        bucket: your-tempo-bucket-name

mimir:
  storage:
    s3:
      bucket: your-mimir-bucket-name
```

### 5. Deploy LGTM Stack

Via Jenkins:
1. Create Jenkins pipeline jobs
2. Run `LGTM-Stack-Deploy` pipeline
3. Select environment and parameters
4. Monitor deployment

Manual deployment:
```bash
# Add Grafana Helm repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Create namespace
kubectl create namespace lgtm-stack

# Deploy LGTM stack
helm install lgtm-stack grafana/lgtm-distributed \
  --namespace lgtm-stack \
  --values helm-values/lgtm-prod-values.yaml

# Deploy Grafana Alloy
helm install grafana-alloy grafana/alloy \
  --namespace lgtm-stack \
  --values helm-values/alloy-prod-values.yaml
```

### 6. Access Grafana

```bash
# Get Grafana URL
kubectl get svc -n lgtm-stack lgtm-stack-grafana

# Get admin password
kubectl get secret lgtm-stack-grafana \
  -n lgtm-stack \
  -o jsonpath="{.data.admin-password}" | base64 --decode
echo
```

---

## 📁 Directory Structure

```
.
├── README.md                          # This file
├── cloudformation/                    # CloudFormation templates
│   ├── 01-eks-cluster.yaml           # EKS cluster, VPC, OIDC
│   ├── 02-nodegroups.yaml            # Node groups with taints
│   ├── 03-s3-buckets.yaml            # S3 storage buckets
│   └── 04-irsa-roles.yaml            # IAM roles for IRSA
├── parameters/                        # CloudFormation parameters
│   ├── prod-cluster.json
│   ├── prod-nodegroups.json
│   ├── prod-s3.json
│   ├── prod-irsa.json
│   ├── staging-*.json
│   └── dev-*.json
├── helm-values/                       # Helm chart values
│   ├── lgtm-prod-values.yaml
│   ├── lgtm-staging-values.yaml
│   ├── lgtm-dev-values.yaml
│   ├── alloy-prod-values.yaml
│   ├── alloy-staging-values.yaml
│   └── alloy-dev-values.yaml
├── jenkins/                           # Jenkins pipeline files
│   ├── Jenkinsfile-deploy
│   └── Jenkinsfile-cleanup
├── scripts/                           # Automation scripts
│   ├── deploy-all.sh                 # Full deployment
│   ├── cleanup-all.sh                # Full cleanup
│   └── update-values.sh              # Helper scripts
└── docs/                              # Documentation
    ├── SETUP.md
    ├── OPERATIONS.md
    └── TROUBLESHOOTING.md
```

---

## 🔧 Detailed Setup

### Step 1: Infrastructure Deployment

#### Option A: Automated (Recommended)

```bash
./scripts/deploy-all.sh
```

#### Option B: Manual Step-by-Step

1. **Deploy EKS Cluster**
```bash
aws cloudformation create-stack \
  --stack-name eks-cluster-stack \
  --template-body file://cloudformation/01-eks-cluster.yaml \
  --parameters file://parameters/prod-cluster.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

# Wait for completion
aws cloudformation wait stack-create-complete \
  --stack-name eks-cluster-stack
```

2. **Update kubeconfig**
```bash
aws eks update-kubeconfig \
  --name my-eks-cluster \
  --region us-east-1
```

3. **Deploy Node Groups**
```bash
aws cloudformation create-stack \
  --stack-name eks-nodegroups-stack \
  --template-body file://cloudformation/02-nodegroups.yaml \
  --parameters file://parameters/prod-nodegroups.json \
  --capabilities CAPABILITY_NAMED_IAM

aws cloudformation wait stack-create-complete \
  --stack-name eks-nodegroups-stack
```

4. **Deploy S3 Buckets**
```bash
aws cloudformation create-stack \
  --stack-name lgtm-s3-stack \
  --template-body file://cloudformation/03-s3-buckets.yaml \
  --parameters file://parameters/prod-s3.json

aws cloudformation wait stack-create-complete \
  --stack-name lgtm-s3-stack
```

5. **Deploy IRSA Roles**
```bash
aws cloudformation create-stack \
  --stack-name lgtm-irsa-stack \
  --template-body file://cloudformation/04-irsa-roles.yaml \
  --parameters file://parameters/prod-irsa.json \
  --capabilities CAPABILITY_NAMED_IAM

aws cloudformation wait stack-create-complete \
  --stack-name lgtm-irsa-stack
```

### Step 2: Jenkins Setup

1. **Install Jenkins Plugins**
   - Kubernetes CLI Plugin
   - AWS Credentials Plugin
   - Pipeline Plugin

2. **Add AWS Credentials**
   - Jenkins → Manage Jenkins → Credentials
   - Add AWS credentials with ID: `aws-credentials-id`

3. **Create Pipeline Jobs**
   
   **Deploy Pipeline:**
   - New Item → Pipeline
   - Name: `LGTM-Stack-Deploy`
   - Pipeline script from SCM
   - Repository: Your Git repo
   - Script Path: `jenkins/Jenkinsfile-deploy`

   **Cleanup Pipeline:**
   - New Item → Pipeline
   - Name: `LGTM-Stack-Cleanup`
   - Pipeline script from SCM
   - Repository: Your Git repo
   - Script Path: `jenkins/Jenkinsfile-cleanup`

### Step 3: Verify Node Taints

```bash
# Check monitoring nodes have taints
kubectl get nodes -l workload=monitoring \
  -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# Expected output:
# NAME                           TAINTS
# ip-10-0-1-123.ec2.internal    [map[effect:NoSchedule key:workload value:monitoring]]
```

---

## 🔄 Operations

### Deploying LGTM Stack

**Via Jenkins:**
1. Open Jenkins
2. Navigate to `LGTM-Stack-Deploy`
3. Click "Build with Parameters"
4. Select:
   - ENVIRONMENT: `prod`
   - ACTION: `deploy`
   - EKS_CLUSTER_NAME: Your cluster name
5. Click "Build"

**Monitoring Deployment:**
```bash
# Watch pods
kubectl get pods -n lgtm-stack -w

# Check pod distribution
kubectl get pods -n lgtm-stack -o wide

# Verify pods on monitoring nodes
kubectl get pods -n lgtm-stack \
  -o wide | grep -E "workload=monitoring"
```

### Updating LGTM Stack

1. Update Helm values file
2. Commit and push changes
3. Run Jenkins pipeline with ACTION: `upgrade`

Or manually:
```bash
helm upgrade lgtm-stack grafana/lgtm-distributed \
  --namespace lgtm-stack \
  --values helm-values/lgtm-prod-values.yaml
```

### Scaling Components

Edit `helm-values/lgtm-prod-values.yaml`:

```yaml
loki:
  ingester:
    replicas: 5  # Increase from 3

mimir:
  ingester:
    replicas: 5  # Increase from 3
```

Apply changes via Jenkins or Helm.

### Cleanup

**Via Jenkins:**
1. Run `LGTM-Stack-Cleanup` pipeline
2. Select DELETE_PVC: `true`
3. Confirm cleanup

**Complete Infrastructure Cleanup:**
```bash
./scripts/cleanup-all.sh
```

This will delete:
- LGTM Helm releases
- Kubernetes resources
- S3 buckets and contents
- Node groups
- EKS cluster
- VPC and networking

---

## 🐛 Troubleshooting

### Pods Not Scheduling

**Symptom**: Pods stuck in `Pending`

**Check:**
```bash
kubectl describe pod <pod-name> -n lgtm-stack
```

**Common Issues:**
- Taints/tolerations mismatch
- Insufficient node resources
- PVC provisioning issues

**Solution:**
```bash
# Verify tolerations in values file match node taints
kubectl get nodes -l workload=monitoring -o yaml | grep -A5 taints

# Check node capacity
kubectl describe nodes -l workload=monitoring | grep -A10 Capacity
```

### S3 Access Issues

**Symptom**: Components can't write to S3

**Check:**
```bash
# Verify service account has IRSA annotation
kubectl get sa lgtm-stack-sa -n lgtm-stack -o yaml

# Check pod has AWS credentials
kubectl exec -it <pod-name> -n lgtm-stack -- env | grep AWS
```

**Solution:**
Ensure Helm values have correct IRSA role ARN.

### High Memory Usage

**Check:**
```bash
kubectl top pods -n lgtm-stack
kubectl top nodes
```

**Solution:**
Adjust resource limits in Helm values or scale nodes.

### Full Troubleshooting Guide

See [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for comprehensive debugging steps.

---

## 💰 Cost Estimation

### Production Environment (Monthly)

| Component | Resource | Monthly Cost |
|-----------|----------|--------------|
| EKS Cluster | Control Plane | $73 |
| EC2 Nodes (General) | 3x m5.xlarge | ~$450 |
| EC2 Nodes (Monitoring) | 3x m5.2xlarge | ~$900 |
| NAT Gateway | 3x NAT | ~$100 |
| EBS Volumes | ~500GB gp3 | ~$40 |
| S3 Storage | ~1TB (first month) | ~$25 |
| Data Transfer | Varies | ~$50 |
| **Total** | | **~$1,640/month** |

### Cost Optimization

1. **Use Spot Instances** for non-prod (60-90% savings)
2. **Single NAT Gateway** for dev/staging
3. **S3 Lifecycle Policies** (configured by default)
4. **Right-size instances** based on actual usage
5. **Schedule shutdowns** for non-prod environments

---

## 📚 Additional Resources

- [Grafana LGTM Documentation](https://grafana.com/docs/)
- [AWS EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Helm Charts Repository](https://github.com/grafana/helm-charts)
- [CloudFormation User Guide](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/)

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

---

## 📝 License

This project is licensed under the MIT License - see the LICENSE file for details.

---

## 🆘 Support

For issues and questions:
1. Check the [Troubleshooting Guide](docs/TROUBLESHOOTING.md)
2. Search existing GitHub issues
3. Create a new issue with detailed information

---

**Happy Observing! 📊📈**