#!/bin/bash

################################################################################
# LGTM Stack Infrastructure Cleanup Script
# This script automates the cleanup of EKS cluster and LGTM stack infrastructure
# WARNING: This will delete ALL resources. Ensure you have backups!
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

# Function to wait for stack deletion
wait_for_stack_deletion() {
    local stack_name=$1
    
    print_info "Waiting for stack $stack_name to be deleted..."
    
    aws cloudformation wait stack-delete-complete \
        --stack-name "$stack_name" \
        --region "$REGION" 2>&1 || true
    
    print_info "✓ Stack $stack_name deleted"
}

# Function to delete stack
delete_stack() {
    local stack_name=$1
    
    if stack_exists "$stack_name"; then
        print_warning "Deleting stack $stack_name..."
        
        aws cloudformation delete-stack \
            --stack-name "$stack_name" \
            --region "$REGION"
        
        wait_for_stack_deletion "$stack_name"
    else
        print_info "Stack $stack_name does not exist, skipping..."
    fi
}

# Function to empty S3 bucket
empty_s3_bucket() {
    local bucket_name=$1
    
    print_info "Emptying S3 bucket: $bucket_name"
    
    # Check if bucket exists
    if aws s3 ls "s3://$bucket_name" 2>&1 | grep -q 'NoSuchBucket'; then
        print_info "Bucket $bucket_name does not exist, skipping..."
        return
    fi
    
    # Delete all versions and delete markers
    aws s3api list-object-versions \
        --bucket "$bucket_name" \
        --output json \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
        2>/dev/null | \
    jq -r '.Objects[]? | "--key \"\(.Key)\" --version-id \"\(.VersionId)\""' | \
    xargs -I {} -P 10 aws s3api delete-object --bucket "$bucket_name" {} || true
    
    # Delete delete markers
    aws s3api list-object-versions \
        --bucket "$bucket_name" \
        --output json \
        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
        2>/dev/null | \
    jq -r '.Objects[]? | "--key \"\(.Key)\" --version-id \"\(.VersionId)\""' | \
    xargs -I {} -P 10 aws s3api delete-object --bucket "$bucket_name" {} || true
    
    # Remove remaining objects
    aws s3 rm "s3://$bucket_name" --recursive || true
    
    print_info "✓ Bucket $bucket_name emptied"
}

# Function to get stack output
get_stack_output() {
    local stack_name=$1
    local output_key=$2
    
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query "Stacks[0].Outputs[?OutputKey=='$output_key'].OutputValue" \
        --output text \
        --region "$REGION" 2>/dev/null || echo ""
}

# Warning and confirmation
show_warning() {
    print_section "⚠️  WARNING ⚠️"
    
    echo -e "${RED}This script will DELETE the following resources:${NC}"
    echo "  1. LGTM Stack Helm releases (if not already deleted)"
    echo "  2. EBS volumes and snapshots"
    echo "  3. Load balancers"
    echo "  4. IRSA IAM roles and policies"
    echo "  5. S3 buckets (Loki, Tempo, Mimir) and ALL their contents"
    echo "  6. EKS node groups"
    echo "  7. EKS cluster"
    echo "  8. VPC, subnets, NAT gateways, etc."
    echo ""
    echo -e "${RED}This action is IRREVERSIBLE!${NC}"
    echo ""
    echo "Cluster: $CLUSTER_NAME"
    echo "Region: $REGION"
    echo "Environment: $ENVIRONMENT"
    echo ""
}

# Main cleanup function
main() {
    print_section "LGTM Stack Infrastructure Cleanup"
    
    show_warning
    
    # First confirmation
    read -p "Are you absolutely sure you want to DELETE all infrastructure? (yes/no): " -r
    echo
    if [[ ! $REPLY =~ ^yes$ ]]; then
        print_info "Cleanup cancelled"
        exit 0
    fi
    
    # Second confirmation for production
    if [[ "$ENVIRONMENT" == "prod" ]]; then
        print_warning "You are about to delete PRODUCTION infrastructure!"
        read -p "Type 'delete-production' to confirm: " -r
        echo
        if [[ ! $REPLY == "delete-production" ]]; then
            print_info "Cleanup cancelled"
            exit 0
        fi
    fi
    
    # Step 1: Delete LGTM Stack Helm releases
    print_section "Step 1: Checking for LGTM Stack Helm releases"
    
    if kubectl get namespace lgtm-stack >/dev/null 2>&1; then
        print_warning "LGTM namespace exists. Checking for Helm releases..."
        
        if helm list -n lgtm-stack | grep -q "lgtm-stack"; then
            print_warning "Found LGTM Stack Helm release. Please run Jenkins cleanup pipeline first!"
            read -p "Have you run the Jenkins cleanup pipeline? (yes/no): " -r
            echo
            if [[ ! $REPLY =~ ^yes$ ]]; then
                print_error "Please run the Jenkins cleanup pipeline first, then re-run this script"
                exit 1
            fi
        fi
        
        # Delete any remaining resources in namespace
        print_info "Deleting remaining resources in lgtm-stack namespace..."
        kubectl delete all --all -n lgtm-stack --timeout=300s || true
        
        # Delete PVCs
        print_info "Deleting PVCs..."
        kubectl delete pvc --all -n lgtm-stack --timeout=300s || true
        
        # Delete namespace
        print_info "Deleting lgtm-stack namespace..."
        kubectl delete namespace lgtm-stack --timeout=300s || true
    else
        print_info "LGTM namespace does not exist, skipping..."
    fi
    
    # Step 2: Delete EBS CSI Driver addon
    print_section "Step 2: Deleting EBS CSI Driver addon"
    
    if aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name aws-ebs-csi-driver \
        --region "$REGION" >/dev/null 2>&1; then
        
        print_info "Deleting EBS CSI Driver addon..."
        aws eks delete-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name aws-ebs-csi-driver \
            --region "$REGION"
        
        # Wait a bit for deletion
        sleep 10
        print_info "✓ EBS CSI Driver addon deleted"
    else
        print_info "EBS CSI Driver addon does not exist, skipping..."
    fi
    
    # Step 3: Delete AWS Load Balancer Controller (if exists)
    print_section "Step 3: Deleting AWS Load Balancer Controller"
    
    if helm list -n kube-system | grep -q "aws-load-balancer-controller"; then
        print_info "Deleting AWS Load Balancer Controller..."
        helm uninstall aws-load-balancer-controller -n kube-system || true
        print_info "✓ AWS Load Balancer Controller deleted"
    else
        print_info "AWS Load Balancer Controller not found, skipping..."
    fi
    
    # Step 4: Delete any remaining load balancers
    print_section "Step 4: Checking for orphaned Load Balancers"
    
    print_info "Listing load balancers that may be associated with the cluster..."
    aws elbv2 describe-load-balancers \
        --region "$REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName, '$CLUSTER_NAME')].LoadBalancerArn" \
        --output text | \
    while read -r lb_arn; do
        if [ -n "$lb_arn" ]; then
            print_warning "Found load balancer: $lb_arn"
            print_warning "Please delete this manually or it may cause issues"
        fi
    done
    
    # Step 5: Get S3 bucket names before deleting IRSA stack
    print_section "Step 5: Getting S3 bucket names"
    
    LOKI_BUCKET=$(get_stack_output "lgtm-s3-stack" "LokiBucketName")
    TEMPO_BUCKET=$(get_stack_output "lgtm-s3-stack" "TempoBucketName")
    MIMIR_BUCKET=$(get_stack_output "lgtm-s3-stack" "MimirBucketName")
    
    print_info "Loki bucket: $LOKI_BUCKET"
    print_info "Tempo bucket: $TEMPO_BUCKET"
    print_info "Mimir bucket: $MIMIR_BUCKET"
    
    # Step 6: Delete IRSA Roles stack
    print_section "Step 6: Deleting IRSA Roles stack"
    delete_stack "lgtm-irsa-stack"
    
    # Step 7: Empty and delete S3 buckets
    print_section "Step 7: Emptying and deleting S3 buckets"
    
    if [ -n "$LOKI_BUCKET" ]; then
        empty_s3_bucket "$LOKI_BUCKET"
    fi
    
    if [ -n "$TEMPO_BUCKET" ]; then
        empty_s3_bucket "$TEMPO_BUCKET"
    fi
    
    if [ -n "$MIMIR_BUCKET" ]; then
        empty_s3_bucket "$MIMIR_BUCKET"
    fi
    
    # Delete S3 stack
    delete_stack "lgtm-s3-stack"
    
    # Step 8: Delete Node Groups stack
    print_section "Step 8: Deleting Node Groups stack"
    delete_stack "eks-nodegroups-stack"
    
    # Wait a bit longer for node groups to fully terminate
    print_info "Waiting for node groups to fully terminate..."
    sleep 30
    
    # Step 9: Delete EKS Cluster stack
    print_section "Step 9: Deleting EKS Cluster stack"
    delete_stack "eks-cluster-stack"
    
    # Step 10: Clean up any remaining resources
    print_section "Step 10: Checking for orphaned resources"
    
    # Check for orphaned EBS volumes
    print_info "Checking for orphaned EBS volumes..."
    aws ec2 describe-volumes \
        --region "$REGION" \
        --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
        --query "Volumes[?State=='available'].VolumeId" \
        --output text | \
    while read -r volume_id; do
        if [ -n "$volume_id" ]; then
            print_warning "Found orphaned volume: $volume_id"
            read -p "Delete this volume? (yes/no): " -r
            if [[ $REPLY =~ ^yes$ ]]; then
                aws ec2 delete-volume --volume-id "$volume_id" --region "$REGION" || true
                print_info "✓ Deleted volume $volume_id"
            fi
        fi
    done
    
    # Check for orphaned security groups
    print_info "Checking for orphaned security groups..."
    aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
        --query "SecurityGroups[].GroupId" \
        --output text | \
    while read -r sg_id; do
        if [ -n "$sg_id" ]; then
            print_warning "Found orphaned security group: $sg_id"
            print_info "You may need to delete this manually after all resources are removed"
        fi
    done
    
    # Summary
    print_section "Cleanup Complete!"
    
    echo "All CloudFormation stacks have been deleted."
    echo ""
    echo "Resources cleaned up:"
    echo "  ✓ LGTM Stack Helm releases"
    echo "  ✓ EBS CSI Driver addon"
    echo "  ✓ IRSA IAM roles and policies"
    echo "  ✓ S3 buckets (Loki, Tempo, Mimir)"
    echo "  ✓ EKS node groups"
    echo "  ✓ EKS cluster"
    echo "  ✓ VPC and networking resources"
    echo ""
    print_warning "Please verify in AWS Console that all resources are deleted:"
    echo "  - CloudFormation stacks"
    echo "  - EKS cluster"
    echo "  - EC2 instances"
    echo "  - Load Balancers"
    echo "  - EBS volumes"
    echo "  - S3 buckets"
    echo "  - IAM roles starting with '$CLUSTER_NAME-'"
    echo ""
    
    # Clean up kubeconfig context
    print_info "Cleaning up kubeconfig context..."
    kubectl config delete-context "arn:aws:eks:$REGION:$(aws sts get-caller-identity --query Account --output text):cluster/$CLUSTER_NAME" 2>/dev/null || true
    
    print_info "Cleanup complete!"
}

# Run main function
main "$@"