#!/bin/bash
set -e

# Usage Check
if [ -z "$1" ]; then
  echo "Usage: ./deploy.sh [fargate|ec2]"
  echo "Example: ./deploy.sh ec2"
  exit 1
fi

STACK=$1
TERRAFORM_DIR="terraform/ec2-free"

if [ "$STACK" == "fargate" ]; then
  TERRAFORM_DIR="terraform/fargate"
elif [ "$STACK" == "ec2" ]; then
  TERRAFORM_DIR="terraform/ec2-free"
else
  echo "Error: Invalid stack '$STACK'. Use 'fargate' or 'ec2'."
  exit 1
fi

echo "🚀 Deploying Stack: $STACK (Dir: $TERRAFORM_DIR)"

# Configuration
AWS_REGION="eu-central-1"
REPO_NAME="svitlo-monitor"

# Load Env
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

echo "--- 1. Initializing Terraform ---"
cd $TERRAFORM_DIR
terraform init

echo "--- 2. Applying Infrastructure ---"
terraform apply -auto-approve \
  -var="bot_token=${BOT_TOKEN}" \
  -var="chat_id=${CHAT_ID}" \
  -var="monitor_config=${MONITOR_CONFIG}" \
  -var="proxy_url=${PROXY_URL}"

# Get ECR URL (Note: Make sure both main.tf files output 'ecr_repository_url')
REPO_URL=$(terraform output -raw ecr_repository_url)

cd ../.. # Go back to root

echo "--- 3. Logging into ECR ---"
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REPO_URL

echo "--- 4. Building & Pushing ---"
# We build specifically for linux/amd64 (Required for t2.micro)
docker build --platform linux/amd64 -t $REPO_NAME ./app
docker tag $REPO_NAME:latest $REPO_URL:latest
docker push $REPO_URL:latest

echo "--- 5. Force Update Service ---"
# We force a new deployment to ensure the EC2 instance picks up the new image
aws ecs update-service --cluster $REPO_NAME-cluster --service $REPO_NAME-service --force-new-deployment --region $AWS_REGION > /dev/null

echo "✅ Deployment Complete ($STACK)!"