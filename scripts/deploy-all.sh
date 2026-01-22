#!/bin/bash

################################################################################
# LGTM Stack Infrastructure Deployment Script
# This script automates the deployment of EKS cluster and LGTM stack infrastructure
################################################################################

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-my-eks-cluster}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
CFN_DIR="cloudformation"
PARAM_DIR="parameters"

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_section() {
    echo ""
    echo "========================================="
    echo "$1"
    echo "========================================="
    echo ""
}

# Function to check if stack exists
stack_exists() {
    aws cloudformation describe-stacks \
        --stack-name "$1" \
        --region "$REGION" \
        >/dev/null 2>&1
}

# Function to wait for stack operation
wait_for_stack() {
    local stack_name=$1
    local operation=$2  # create or update
    
    print_info "Waiting for stack $stack_name to complete $operation..."
    
    if [ "$operation" == "create" ]; then
        aws cloudformation wait stack-create-complete \
            --stack-name "$stack_name" \
            --region "$REGION"
    else
        aws cloudformation wait stack-update-complete \
            --stack-name "$stack_name" \
            --region "$REGION"
    fi
    
    if [ $? -eq 0 ]; then
        print_info "✓ Stack $stack_name $operation completed successfully"
        return 0
    else
        print_error "✗ Stack $stack_name $operation failed"
        return 1
    fi
}

# Function to create or update stack
deploy_stack() {
    local stack_name=$1
    local template_file=$2
    local params_file=$3
    local capabilities=$4
    
    if stack_exists "$stack_name"; then
        print_warning "Stack $stack_name already exists. Updating..."
        
        aws cloudformation update-stack \
            --stack-name "$stack_name" \
            --template-body "file://$template_file" \
            --parameters "file://$params_file" \
            ${capabilities:+--capabilities "$capabilities"} \
            --region "$REGION" 2>&1 | tee /tmp/cfn-output.txt
        
        if grep -q "No updates are to be performed" /tmp/cfn-output.txt; then
            print_info "No updates needed for stack $stack_name"
            return 0
        fi
        
        wait_for_stack "$stack_name" "update"
    else
        print_info "Creating stack $stack_name..."
        
        aws cloudformation create-stack \
            --stack-name "$stack_name" \
            --template-body "file://$template_file" \
            --parameters "file://$params_file" \
            ${capabilities:+--capabilities "$capabilities"} \
            --region "$REGION"
        
        wait_for_stack "$stack_name" "create"
    fi
}

# Function to get stack output
get_stack_output() {
    local stack_name=$1
    local output_key=$2
    
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query "Stacks[0].Outputs[?OutputKey=='$output_key'].OutputValue" \
        --output text \
        --region "$REGION"
}

# Function to check prerequisites
check_prerequisites() {
    print_section "Checking Prerequisites"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found. Please install it first."
        exit 1
    fi
    print_info "✓ AWS CLI installed"
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found. Please install it first."
        exit 1
    fi
    print_info "✓ kubectl installed"
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        print_error "helm not found. Please install it first."
        exit 1
    fi
    print_info "✓ Helm installed"
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Please configure them first."
        exit 1
    fi
    print_info "✓ AWS credentials configured"
    
    # Check if CloudFormation templates exist
    if [ ! -f "$CFN_DIR/01-eks-cluster.yaml" ]; then
        print_error "CloudFormation templates not found in $CFN_DIR/"
        exit 1
    fi
    print_info "✓ CloudFormation templates found"
}

# Main deployment function
main() {
    print_section "LGTM Stack Infrastructure Deployment"
    print_info "Region: $REGION"
    print_info "Cluster Name: $CLUSTER_NAME"
    print_info "Environment: $ENVIRONMENT"
    
    check_prerequisites
    
    # Step 1: Deploy EKS Cluster
    print_section "Step 1: Deploying EKS Cluster"
    deploy_stack \
        "eks-cluster-stack" \
        "$CFN_DIR/01-eks-cluster.yaml" \
        "$PARAM_DIR/${ENVIRONMENT}-cluster.json" \
        "CAPABILITY_NAMED_IAM"
    
    # Step 2: Update kubeconfig
    print_section "Step 2: Updating kubeconfig"
    aws eks update-kubeconfig \
        --name "$CLUSTER_NAME" \
        --region "$REGION"
    print_info "✓ Kubeconfig updated"
    
    # Verify cluster connection
    kubectl cluster-info
    
    # Step 3: Deploy Node Groups
    print_section "Step 3: Deploying Node Groups"
    deploy_stack \
        "eks-nodegroups-stack" \
        "$CFN_DIR/02-nodegroups.yaml" \
        "$PARAM_DIR/${ENVIRONMENT}-nodegroups.json" \
        "CAPABILITY_NAMED_IAM"
    
    # Wait for nodes to be ready
    print_info "Waiting for nodes to be ready..."
    sleep 30
    kubectl get nodes -o wide
    
    # Verify monitoring node taints
    print_info "Verifying monitoring node taints..."
    kubectl get nodes -l workload=monitoring -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
    
    # Step 4: Deploy S3 Buckets
    print_section "Step 4: Deploying S3 Buckets"
    deploy_stack \
        "lgtm-s3-stack" \
        "$CFN_DIR/03-s3-buckets.yaml" \
        "$PARAM_DIR/${ENVIRONMENT}-s3.json" \
        ""
    
    # Step 5: Deploy IRSA Roles
    print_section "Step 5: Deploying IRSA Roles"
    deploy_stack \
        "lgtm-irsa-stack" \
        "$CFN_DIR/04-irsa-roles.yaml" \
        "$PARAM_DIR/${ENVIRONMENT}-irsa.json" \
        "CAPABILITY_NAMED_IAM"
    
    # Step 6: Install EBS CSI Driver
    print_section "Step 6: Installing EBS CSI Driver"
    
    EBS_CSI_ROLE_ARN=$(get_stack_output "lgtm-irsa-stack" "EBSCSIDriverRoleArn")
    print_info "EBS CSI Driver Role ARN: $EBS_CSI_ROLE_ARN"
    
    # Check if addon already exists
    if aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name aws-ebs-csi-driver \
        --region "$REGION" >/dev/null 2>&1; then
        print_warning "EBS CSI Driver addon already exists, updating..."
        aws eks update-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name aws-ebs-csi-driver \
            --service-account-role-arn "$EBS_CSI_ROLE_ARN" \
            --region "$REGION" || true
    else
        print_info "Installing EBS CSI Driver addon..."
        aws eks create-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name aws-ebs-csi-driver \
            --service-account-role-arn "$EBS_CSI_ROLE_ARN" \
            --region "$REGION"
    fi
    
    print_info "Waiting for EBS CSI Driver to be active..."
    aws eks wait addon-active \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name aws-ebs-csi-driver \
        --region "$REGION" || true
    
    print_info "✓ EBS CSI Driver installed"
    
    # Verify EBS CSI Driver pods
    kubectl get pods -n kube-system | grep ebs-csi
    
    # Step 7: Install AWS Load Balancer Controller (Optional)
    print_section "Step 7: Installing AWS Load Balancer Controller (Optional)"
    
    read -p "Do you want to install AWS Load Balancer Controller? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        LBC_ROLE_ARN=$(get_stack_output "lgtm-irsa-stack" "AWSLoadBalancerControllerRoleArn")
        print_info "AWS LB Controller Role ARN: $LBC_ROLE_ARN"
        
        # Add the EKS chart repo
        helm repo add eks https://aws.github.io/eks-charts
        helm repo update
        
        # Install or upgrade AWS Load Balancer Controller
        helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
            -n kube-system \
            --set clusterName="$CLUSTER_NAME" \
            --set serviceAccount.create=true \
            --set serviceAccount.name=aws-load-balancer-controller \
            --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$LBC_ROLE_ARN"
        
        print_info "✓ AWS Load Balancer Controller installed"
        
        # Verify installation
        kubectl get deployment -n kube-system aws-load-balancer-controller
    else
        print_info "Skipping AWS Load Balancer Controller installation"
    fi
    
    # Display summary
    print_section "Deployment Summary"
    
    LGTM_ROLE_ARN=$(get_stack_output "lgtm-irsa-stack" "LGTMStackIRSARoleArn")
    LOKI_BUCKET=$(get_stack_output "lgtm-s3-stack" "LokiBucketName")
    TEMPO_BUCKET=$(get_stack_output "lgtm-s3-stack" "TempoBucketName")
    MIMIR_BUCKET=$(get_stack_output "lgtm-s3-stack" "MimirBucketName")
    
    echo "Infrastructure deployment completed successfully!"
    echo ""
    echo "IRSA Role ARN (for Helm values):"
    echo "  $LGTM_ROLE_ARN"
    echo ""
    echo "S3 Bucket Names:"
    echo "  Loki:  $LOKI_BUCKET"
    echo "  Tempo: $TEMPO_BUCKET"
    echo "  Mimir: $MIMIR_BUCKET"
    echo ""
    echo "Next Steps:"
    echo "1. Update helm-values/lgtm-${ENVIRONMENT}-values.yaml with:"
    echo "   - IRSA Role ARN: $LGTM_ROLE_ARN"
    echo "   - Bucket names listed above"
    echo ""
    echo "2. Run the Jenkins deployment pipeline with:"
    echo "   - ENVIRONMENT: $ENVIRONMENT"
    echo "   - EKS_CLUSTER_NAME: $CLUSTER_NAME"
    echo "   - AWS_REGION: $REGION"
    echo ""
    echo "3. Verify LGTM stack deployment:"
    echo "   kubectl get pods -n lgtm-stack"
    echo "   kubectl get nodes -l workload=monitoring -o wide"
    echo ""
    
    # Save outputs to file
    OUTPUT_FILE="deployment-outputs-${ENVIRONMENT}.txt"
    cat > "$OUTPUT_FILE" <<EOF
LGTM Stack Deployment Outputs
Generated: $(date)
Region: $REGION
Cluster: $CLUSTER_NAME
Environment: $ENVIRONMENT

IRSA Role ARN:
$LGTM_ROLE_ARN

S3 Buckets:
Loki:  $LOKI_BUCKET
Tempo: $TEMPO_BUCKET
Mimir: $MIMIR_BUCKET

Kubeconfig:
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

CloudFormation Stacks:
- eks-cluster-stack
- eks-nodegroups-stack
- lgtm-s3-stack
- lgtm-irsa-stack
EOF
    
    print_info "Outputs saved to $OUTPUT_FILE"
}

# Run main function
main "$@"