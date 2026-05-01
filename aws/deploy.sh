#!/usr/bin/env bash
# One-command deploy of the 3-node Cassandra sandbox to AWS via CloudFormation.
# Each Cassandra node runs on its own EC2 host — a genuine distributed cluster.
#
# Prereqs: aws CLI configured (`aws configure`), an existing EC2 key pair.
#
# Usage:
#   ./deploy.sh <key-pair-name> [region]   Deploy (or update) the stack
#   ./deploy.sh --status        [region]   Show stack outputs + node IPs
#   ./deploy.sh --ring          [region]   Show nodetool status from node 1
#   ./deploy.sh --stop          [region]   Stop all 3 EC2s (save cost)
#   ./deploy.sh --start         [region]   Start all 3 EC2s after stopping
#   ./deploy.sh --delete        [region]   Tear down everything (irreversible)
#
# Cost: 3 × t4g.small ≈ $0.05/hr ≈ $37/mo if left running.
#       Stop instances when not in use — storage costs ~$0.24/mo per node.

set -euo pipefail
cd "$(dirname "$0")"

STACK_NAME="cassandra-sandbox"
REGION="${2:-${AWS_REGION:-us-east-1}}"

_instance_ids() {
  aws cloudformation describe-stack-resources \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "StackResources[?ResourceType=='AWS::EC2::Instance'].PhysicalResourceId" \
    --output text
}

case "${1:-}" in
  -h|--help|"")
    cat <<EOF
Cassandra 3-node sandbox — AWS deploy

  ./deploy.sh <key-pair-name> [region]   Deploy (or update) the stack
  ./deploy.sh --status        [region]   Show stack outputs + node IPs
  ./deploy.sh --ring          [region]   Show nodetool status from node 1
  ./deploy.sh --stop          [region]   Stop all 3 EC2s (pause cost)
  ./deploy.sh --start         [region]   Restart all 3 EC2s
  ./deploy.sh --delete        [region]   Destroy everything

Default region: us-east-1. Override with the second arg or AWS_REGION env var.
EOF
    exit 0
    ;;

  --status)
    aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" --region "$REGION" \
      --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}' \
      --output table
    exit 0
    ;;

  --ring)
    NODE1_IP=$(aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" --region "$REGION" \
      --query "Stacks[0].Outputs[?OutputKey=='Node1PublicIp'].OutputValue" \
      --output text)
    echo "Connecting to $NODE1_IP to check ring (you may see an SSH prompt)..."
    ssh -o StrictHostKeyChecking=no "ec2-user@$NODE1_IP" \
      'docker exec cassandra nodetool status'
    exit 0
    ;;

  --stop)
    IDS=$(_instance_ids)
    echo "==> Stopping instances: $IDS"
    # shellcheck disable=SC2086
    aws ec2 stop-instances --instance-ids $IDS --region "$REGION" --output table
    echo "    Instances stopping. Data is preserved on EBS."
    exit 0
    ;;

  --start)
    IDS=$(_instance_ids)
    echo "==> Starting instances: $IDS"
    # shellcheck disable=SC2086
    aws ec2 start-instances --instance-ids $IDS --region "$REGION" --output table
    echo "    Cassandra auto-starts (--restart unless-stopped). Allow ~3 min for ring to reform."
    exit 0
    ;;

  --delete)
    echo "==> Deleting stack $STACK_NAME in $REGION (all data will be lost)"
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
    echo "    Waiting for deletion to complete..."
    aws cloudformation wait stack-delete-complete \
      --stack-name "$STACK_NAME" --region "$REGION"
    echo "    Done."
    exit 0
    ;;
esac

KEY_PAIR="$1"

echo "==> Detecting your public IP..."
MY_IP=$(curl -fsSL https://checkip.amazonaws.com | tr -d '[:space:]')
if [[ ! "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: could not detect public IP (got: '$MY_IP')"; exit 1
fi
ALLOWED_CIDR="${MY_IP}/32"
echo "    Restricting SSH + CQL to ${ALLOWED_CIDR}"

echo
echo "==> Deploying stack '$STACK_NAME' in $REGION"
echo "    (~5 min for CFN; another ~8-10 min for Cassandra ring to form)"
aws cloudformation deploy \
  --template-file cloudformation.yaml \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --parameter-overrides \
      AllowedCidr="$ALLOWED_CIDR" \
      KeyPairName="$KEY_PAIR" \
  --no-fail-on-empty-changeset

echo
echo "==> Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs' \
  --output table

echo
echo "==> Next steps:"
echo "    1. Wait ~8-10 min for Cassandra to finish bootstrapping on all 3 nodes."
echo "    2. Check ring:   ./deploy.sh --ring $REGION"
echo "    3. Connect:      cqlsh <Node1PublicIp> (from the table above)"
echo "    4. Stop to save: ./deploy.sh --stop $REGION"
