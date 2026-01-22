# CloudFormation Deployment Guide for LGTM Stack on EKS

## Overview

This guide walks you through deploying the complete LGTM stack infrastructure using AWS CloudFormation templates.

## Directory Structure

```
cloudformation/
├── 01-eks-cluster.yaml           # VPC, EKS cluster, OIDC provider
├── 02-nodegroups.yaml            # General and Monitoring node groups with taints
├── 03-s3-buckets.yaml            # S3 buckets for Loki, Tempo, Mimir
├── 04-irsa-roles.yaml            # IAM roles for service accounts (IRSA)
├── parameters/
│   ├── prod-cluster.json
│   ├── prod-nodegroups.json
│   ├── prod-s3.json
│   └── prod-irsa.json
└── scripts/
    ├── deploy-all.sh
    ├── update-all.sh
    └── delete-all.sh
```

---

## Deployment Order

**IMPORTANT**: Deploy stacks in this exact order as they have dependencies.

1. **EKS Cluster** (creates VPC, cluster, OIDC)
2. **Node Groups** (depends on EKS cluster)
3. **S3 Buckets** (can be parallel with node groups)
4. **IRSA Roles** (depends on EKS cluster and S3 buckets)

---

## Step-by-Step Deployment

### Step 1: Deploy EKS Cluster

```bash
# Create the stack
aws cloudformation create-stack \
  --stack-name eks-cluster-stack \
  --template-body file://01-eks-cluster.yaml \
  --parameters \
    ParameterKey=ClusterName,ParameterValue=my-eks-cluster \
    ParameterKey=KubernetesVersion,ParameterValue=1.31 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

# Wait for completion (15-20 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name eks-cluster-stack \
  --region us-east-1

# Verify outputs
aws cloudformation describe-stacks \
  --stack-name eks-cluster-stack \
  --query 'Stacks[0].Outputs' \
  --region us-east-1
```

### Step 2: Update kubeconfig

```bash
# Configure kubectl to use the new cluster
aws eks update-kubeconfig \
  --name my-eks-cluster \
  --region us-east-1

# Verify connection
kubectl cluster-info
kubectl get nodes  # Should be empty at this point
```

### Step 3: Deploy Node Groups

```bash
# Create the node groups stack
aws cloudformation create-stack \
  --stack-name eks-nodegroups-stack \
  --template-body file://02-nodegroups.yaml \
  --parameters \
    ParameterKey=ClusterStackName,ParameterValue=eks-cluster-stack \
    ParameterKey=ClusterName,ParameterValue=my-eks-cluster \
    ParameterKey=GeneralNodeGroupDesiredSize,ParameterValue=3 \
    ParameterKey=GeneralNodeInstanceType,ParameterValue=m5.xlarge \
    ParameterKey=MonitoringNodeGroupDesiredSize,ParameterValue=3 \
    ParameterKey=MonitoringNodeInstanceType,ParameterValue=m5.2xlarge \
    ParameterKey=NodeVolumeSize,ParameterValue=100 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

# Wait for completion (10-15 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name eks-nodegroups-stack \
  --region us-east-1

# Verify nodes are ready
kubectl get nodes -o wide

# Verify monitoring node taints
kubectl get nodes -l workload=monitoring -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

Expected output:
```
NAME                                          TAINTS
ip-10-0-1-123.ec2.internal                   [map[effect:NoSchedule key:workload value:monitoring]]
ip-10-0-2-456.ec2.internal                   [map[effect:NoSchedule key:workload value:monitoring]]
ip-10-0-3-789.ec2.internal                   [map[effect:NoSchedule key:workload value:monitoring]]
```

### Step 4: Deploy S3 Buckets

```bash
# Create the S3 buckets stack
aws cloudformation create-stack \
  --stack-name lgtm-s3-stack \
  --template-body file://03-s3-buckets.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=prod \
    ParameterKey=ClusterName,ParameterValue=my-eks-cluster \
    ParameterKey=EnableVersioning,ParameterValue=true \
    ParameterKey=EnableLifecyclePolicy,ParameterValue=true \
    ParameterKey=RetentionDays,ParameterValue=90 \
  --region us-east-1

# Wait for completion (2-3 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name lgtm-s3-stack \
  --region us-east-1

# Verify bucket creation
aws cloudformation describe-stacks \
  --stack-name lgtm-s3-stack \
  --query 'Stacks[0].Outputs' \
  --region us-east-1

# List the buckets
aws s3 ls | grep my-eks-cluster
```

### Step 5: Deploy IRSA Roles

```bash
# Create the IRSA roles stack
aws cloudformation create-stack \
  --stack-name lgtm-irsa-stack \
  --template-body file://04-irsa-roles.yaml \
  --parameters \
    ParameterKey=ClusterStackName,ParameterValue=eks-cluster-stack \
    ParameterKey=S3StackName,ParameterValue=lgtm-s3-stack \
    ParameterKey=ClusterName,ParameterValue=my-eks-cluster \
    ParameterKey=Namespace,ParameterValue=lgtm-stack \
    ParameterKey=ServiceAccountName,ParameterValue=lgtm-stack-sa \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

# Wait for completion (2-3 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name lgtm-irsa-stack \
  --region us-east-1

# Get the IRSA role ARN (you'll need this for Helm values)
aws cloudformation describe-stacks \
  --stack-name lgtm-irsa-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`LGTMStackIRSARoleArn`].OutputValue' \
  --output text \
  --region us-east-1
```

### Step 6: Install EBS CSI Driver

```bash
# Get the EBS CSI Driver role ARN
EBS_CSI_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name lgtm-irsa-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`EBSCSIDriverRoleArn`].OutputValue' \
  --output text \
  --region us-east-1)

# Install EBS CSI Driver addon
aws eks create-addon \
  --cluster-name my-eks-cluster \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn $EBS_CSI_ROLE_ARN \
  --region us-east-1

# Wait for addon to be active
aws eks wait addon-active \
  --cluster-name my-eks-cluster \
  --addon-name aws-ebs-csi-driver \
  --region us-east-1

# Verify EBS CSI Driver is running
kubectl get pods -n kube-system | grep ebs-csi
```

### Step 7: Install AWS Load Balancer Controller (Optional)

```bash
# Get the Load Balancer Controller role ARN
LBC_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name lgtm-irsa-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`AWSLoadBalancerControllerRoleArn`].OutputValue' \
  --output text \
  --region us-east-1)

# Add the EKS chart repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install AWS Load Balancer Controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=my-eks-cluster \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$LBC_ROLE_ARN

# Verify installation
kubectl get deployment -n kube-system aws-load-balancer-controller
```

### Step 8: Update Helm Values with IRSA Role ARN

Get the LGTM Stack IRSA role ARN and update your Helm values file:

```bash
# Get the role ARN
LGTM_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name lgtm-irsa-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`LGTMStackIRSARoleArn`].OutputValue' \
  --output text \
  --region us-east-1)

echo "Update your helm-values/lgtm-prod-values.yaml with:"
echo "serviceAccount:"
echo "  annotations:"
echo "    eks.amazonaws.com/role-arn: $LGTM_ROLE_ARN"

# Also get bucket names
LOKI_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name lgtm-s3-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`LokiBucketName`].OutputValue' \
  --output text \
  --region us-east-1)

TEMPO_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name lgtm-s3-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`TempoBucketName`].OutputValue' \
  --output text \
  --region us-east-1)

MIMIR_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name lgtm-s3-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`MimirBucketName`].OutputValue' \
  --output text \
  --region us-east-1)

echo ""
echo "Update bucket names in your values file:"
echo "Loki bucket: $LOKI_BUCKET"
echo "Tempo bucket: $TEMPO_BUCKET"
echo "Mimir bucket: $MIMIR_BUCKET"
```

### Step 9: Deploy LGTM Stack via Jenkins

Now you can proceed with the Jenkins pipeline deployment as described in the main documentation.

---

## Using Parameter Files

Create parameter files for easier stack management:

**parameters/prod-cluster.json:**
```json
[
  {
    "ParameterKey": "ClusterName",
    "ParameterValue": "my-eks-cluster"
  },
  {
    "ParameterKey": "KubernetesVersion",
    "ParameterValue": "1.31"
  }
]
```

**parameters/prod-nodegroups.json:**
```json
[
  {
    "ParameterKey": "ClusterStackName",
    "ParameterValue": "eks-cluster-stack"
  },
  {
    "ParameterKey": "ClusterName",
    "ParameterValue": "my-eks-cluster"
  },
  {
    "ParameterKey": "GeneralNodeGroupDesiredSize",
    "ParameterValue": "3"
  },
  {
    "ParameterKey": "GeneralNodeInstanceType",
    "ParameterValue": "m5.xlarge"
  },
  {
    "ParameterKey": "MonitoringNodeGroupDesiredSize",
    "ParameterValue": "3"
  },
  {
    "ParameterKey": "MonitoringNodeInstanceType",
    "ParameterValue": "m5.2xlarge"
  }
]
```

Deploy using parameter files:

```bash
aws cloudformation create-stack \
  --stack-name eks-cluster-stack \
  --template-body file://01-eks-cluster.yaml \
  --parameters file://parameters/prod-cluster.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

---

## Automated Deployment Script

Create `scripts/deploy-all.sh`:

```bash
#!/bin/bash
set -e

REGION="us-east-1"
CLUSTER_NAME="my-eks-cluster"

echo "========================================="
echo "Deploying LGTM Stack Infrastructure"
echo "========================================="

# Step 1: Deploy EKS Cluster
echo "Step 1: Creating EKS Cluster..."
aws cloudformation create-stack \
  --stack-name eks-cluster-stack \
  --template-body file://01-eks-cluster.yaml \
  --parameters file://parameters/prod-cluster.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $REGION

aws cloudformation wait stack-create-complete \
  --stack-name eks-cluster-stack \
  --region $REGION

echo "✓ EKS Cluster created"

# Step 2: Update kubeconfig
echo "Step 2: Updating kubeconfig..."
aws eks update-kubeconfig \
  --name $CLUSTER_NAME \
  --region $REGION

echo "✓ Kubeconfig updated"

# Step 3: Deploy Node Groups
echo "Step 3: Creating Node Groups..."
aws cloudformation create-stack \
  --stack-name eks-nodegroups-stack \
  --template-body file://02-nodegroups.yaml \
  --parameters file://parameters/prod-nodegroups.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $REGION

aws cloudformation wait stack-create-complete \
  --stack-name eks-nodegroups-stack \
  --region $REGION

echo "✓ Node Groups created"

# Step 4: Deploy S3 Buckets
echo "Step 4: Creating S3 Buckets..."
aws cloudformation create-stack \
  --stack-name lgtm-s3-stack \
  --template-body file://03-s3-buckets.yaml \
  --parameters file://parameters/prod-s3.json \
  --region $REGION

aws cloudformation wait stack-create-complete \
  --stack-name lgtm-s3-stack \
  --region $REGION

echo "✓ S3 Buckets created"

# Step 5: Deploy IRSA Roles
echo "Step 5: Creating IRSA Roles..."
aws cloudformation create-stack \
  --stack-name lgtm-irsa-stack \
  --template-body file://04-irsa-roles.yaml \
  --parameters file://parameters/prod-irsa.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $REGION

aws cloudformation wait stack-create-complete \
  --stack-name lgtm-irsa-stack \
  --region $REGION

echo "✓ IRSA Roles created"

# Step 6: Install EBS CSI Driver
echo "Step 6: Installing EBS CSI Driver..."
EBS_CSI_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name lgtm-irsa-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`EBSCSIDriverRoleArn`].OutputValue' \
  --output text \
  --region $REGION)

aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn $EBS_CSI_ROLE_ARN \
  --region $REGION || echo "EBS CSI Driver addon already exists"

echo "✓ EBS CSI Driver installed"

# Display outputs
echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""

LGTM_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name lgtm-irsa-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`LGTMStackIRSARoleArn`].OutputValue' \
  --output text \
  --region $REGION)

echo "LGTM Stack IRSA Role ARN:"
echo "$LGTM_ROLE_ARN"
echo ""

echo "Next steps:"
echo "1. Update helm-values/lgtm-prod-values.yaml with the IRSA role ARN"
echo "2. Run the Jenkins deployment pipeline"
echo "3. Verify pods are scheduled on monitoring nodes with taints"
```

Make it executable and run:

```bash
chmod +x scripts/deploy-all.sh
./scripts/deploy-all.sh
```

---

## Stack Updates

To update a stack (e.g., change instance types):

```bash
# Update the stack
aws cloudformation update-stack \
  --stack-name eks-nodegroups-stack \
  --template-body file://02-nodegroups.yaml \
  --parameters file://parameters/prod-nodegroups.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

# Wait for completion
aws cloudformation wait stack-update-complete \
  --stack-name eks-nodegroups-stack \
  --region us-east-1
```

---

## Stack Deletion

**WARNING**: This will delete all resources. Always backup data first!

Delete in reverse order:

```bash
# 1. Delete LGTM Stack (via Jenkins cleanup pipeline first!)

# 2. Delete IRSA Roles
aws cloudformation delete-stack \
  --stack-name lgtm-irsa-stack \
  --region us-east-1

# 3. Delete S3 Buckets (must be empty)
# First, empty the buckets
aws s3 rm s3://your-loki-bucket --recursive
aws s3 rm s3://your-tempo-bucket --recursive
aws s3 rm s3://your-mimir-bucket --recursive

aws cloudformation delete-stack \
  --stack-name lgtm-s3-stack \
  --region us-east-1

# 4. Delete Node Groups
aws cloudformation delete-stack \
  --stack-name eks-nodegroups-stack \
  --region us-east-1

# Wait for node groups to be deleted
aws cloudformation wait stack-delete-complete \
  --stack-name eks-nodegroups-stack \
  --region us-east-1

# 5. Delete EKS Cluster
aws cloudformation delete-stack \
  --stack-name eks-cluster-stack \
  --region us-east-1
```

---

## Troubleshooting

### Stack Creation Fails

```bash
# Check stack events for errors
aws cloudformation describe-stack-events \
  --stack-name <stack-name> \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]' \
  --region us-east-1

# Get detailed error
aws cloudformation describe-stack-events \
  --stack-name <stack-name> \
  --max-items 50 \
  --region us-east-1
```

### OIDC Provider Issues

If IRSA roles fail to create, verify OIDC provider:

```bash
# Get OIDC provider URL
aws eks describe-cluster \
  --name my-eks-cluster \
  --query "cluster.identity.oidc.issuer" \
  --output text \
  --region us-east-1

# List OIDC providers
aws iam list-open-id-connect-providers
```

### Node Group Not Joining Cluster

```bash
# Check node group status
aws eks describe-nodegroup \
  --cluster-name my-eks-cluster \
  --nodegroup-name <nodegroup-name> \
  --region us-east-1

# Check CloudWatch Logs
aws logs tail /aws/eks/my-eks-cluster/cluster --follow
```

---

## Cost Optimization Tips

1. **Use Spot Instances for Dev**: Modify node group template to use Spot instances in non-production
2. **Right-size Instances**: Monitor actual usage and adjust instance types
3. **Enable S3 Lifecycle Policies**: Use the lifecycle parameters to move old data to cheaper storage
4. **Use Single NAT Gateway for Dev**: Modify VPC template for non-production environments
5. **Schedule Node Group Scaling**: Use AWS Instance Scheduler to shut down dev/staging during off-hours

---

## Monitoring CloudFormation Stacks

```bash
# List all LGTM-related stacks
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query 'StackSummaries[?contains(StackName, `eks`) || contains(StackName, `lgtm`)]' \
  --region us-east-1

# Get stack outputs
aws cloudformation describe-stacks \
  --stack-name <stack-name> \
  --query 'Stacks[0].Outputs' \
  --region us-east-1

# Export stack outputs to file
aws cloudformation describe-stacks \
  --stack-name lgtm-irsa-stack \
  --query 'Stacks[0].Outputs' \
  --output json > stack-outputs.json
```

---

## Next Steps

After infrastructure is deployed:
1. ✅ EKS cluster is running
2. ✅ Node groups created (general and monitoring with taints)
3. ✅ S3 buckets configured
4. ✅ IRSA roles created
5. ✅ EBS CSI Driver installed
6. → Update Helm values with bucket names and IRSA role ARN
7. → Run Jenkins deployment pipeline
8. → Verify LGTM stack is running
9. → Access Grafana and configure dashboards