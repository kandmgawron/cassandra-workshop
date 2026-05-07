#!/usr/bin/env bash
# One-command deploy of the 3-node Cassandra sandbox to AWS via CloudFormation.
# Each Cassandra node runs on its own EC2 host — a genuine distributed cluster.
#
# Prereqs: aws CLI configured (`aws configure`), an existing EC2 key pair.
#
# Usage:
#   ./deploy.sh <key-pair-name> [region]            Deploy (or update) the stack
#   ./deploy.sh --status        [region]            Show stack outputs + node IPs
#   ./deploy.sh --ring          [region] [key.pem]  Show nodetool status from node 1
#   ./deploy.sh --stop          [region]            Stop all 3 EC2s (save cost)
#   ./deploy.sh --start         [region]            Start all 3 EC2s after stopping
#   ./deploy.sh --delete        [region]            Tear down everything (irreversible)
#
# Cost: 3 × t4g.small ≈ $0.05/hr ≈ $37/mo if left running.
#       Stop instances when not in use — storage costs ~$0.24/mo per node.

set -euo pipefail
cd "$(dirname "$0")"

STACK_NAME="cassandra-sandbox"
REGION="${2:-${AWS_REGION:-us-east-1}}"

# Locate the .pem key file for SSH subcommands.
# Tries (in order): explicit $1 arg, ./<KeyPairName>.pem, ~/.ssh/<KeyPairName>.pem, ~/.ssh/<KeyPairName>
_find_key_file() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    # Resolve relative paths from CWD
    if [[ ! "$explicit" = /* ]]; then explicit="$(pwd)/$explicit"; fi
    if [[ ! -f "$explicit" ]]; then
      echo "ERROR: key file not found: $explicit" >&2; exit 1
    fi
    echo "$explicit"; return
  fi

  # Look up the key pair name from the deployed stack parameters
  local kp
  kp=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Parameters[?ParameterKey=='KeyPairName'].ParameterValue" \
    --output text 2>/dev/null || true)

  if [[ -z "$kp" || "$kp" == "None" ]]; then
    echo "ERROR: could not determine key pair name from stack — pass it explicitly: ./deploy.sh --ring [region] <key.pem>" >&2
    exit 1
  fi

  # Search common locations
  local candidates=(
    "$(pwd)/${kp}.pem"
    "$(pwd)/${kp}"
    "${HOME}/.ssh/${kp}.pem"
    "${HOME}/.ssh/${kp}"
  )
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then echo "$f"; return; fi
  done

  echo "ERROR: key file for '$kp' not found. Tried: ${candidates[*]}" >&2
  echo "       Pass it explicitly: ./deploy.sh --ring [region] <key.pem>" >&2
  exit 1
}

_instance_ids() {
  aws cloudformation describe-stack-resources \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "StackResources[?ResourceType=='AWS::EC2::Instance'].PhysicalResourceId" \
    --output text
}

# Delete any VPC endpoints and terminate any EC2 instances that would block
# subnet/VPC deletion. CloudFormation can't delete a subnet while ENIs remain,
# and interface-type VPC endpoints create ENIs that CF doesn't manage.
_pre_delete_cleanup() {
  local vpc_id
  vpc_id=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=cassandra-sandbox-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)

  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then return; fi
  echo "    VPC: $vpc_id"

  # Terminate any EC2 instances still running in this VPC and wait for them
  # to be fully terminated before touching endpoints — an endpoint reports
  # "in use" until all instances using it are gone.
  local iids
  iids=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
  if [[ -n "$iids" ]]; then
    echo "    Terminating instances: $iids"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --region "$REGION" --instance-ids $iids --output text &>/dev/null || true
    echo "    Waiting for instances to terminate fully..."
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $iids || true
    echo "    Instances terminated ✓"
  fi

  # Delete any VPC endpoints — interface endpoints leave ENIs that block subnet deletion.
  # Must happen AFTER instances are terminated (endpoint stays "in use" while instances run).
  local epids
  epids=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=vpc-endpoint-state,Values=pending,available" \
    --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)
  if [[ -n "$epids" ]]; then
    echo "    Deleting VPC endpoints: $epids"
    # shellcheck disable=SC2086
    aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids $epids --output text &>/dev/null || true
    echo "    Waiting 30s for ENIs to detach..."
    sleep 30
  fi
}

case "${1:-}" in
  -h|--help|"")
    cat <<EOF
Cassandra 3-node sandbox — AWS deploy

  ./deploy.sh <key-pair-name> [region]            Deploy (or update) the stack
  ./deploy.sh --status        [region]            Show stack outputs + node IPs
  ./deploy.sh --ring          [region] [key.pem]  Show nodetool status from node 1
  ./deploy.sh --stop          [region]            Stop all 3 EC2s (pause cost)
  ./deploy.sh --start         [region]            Restart all 3 EC2s
  ./deploy.sh --delete        [region]            Destroy everything

Default region: us-east-1. Override with the second arg or AWS_REGION env var.
Key file for --ring: auto-detected from ./<keypair>.pem or ~/.ssh/<keypair>.pem,
                     or pass it as the third argument.
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
    KEY_FILE=$(_find_key_file "${3:-}")
    NODE1_IP=$(aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" --region "$REGION" \
      --query "Stacks[0].Outputs[?OutputKey=='Node1PublicIp'].OutputValue" \
      --output text)
    echo "Connecting to $NODE1_IP using $KEY_FILE..."
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no "ec2-user@$NODE1_IP" '
      STATUS=$(sudo docker inspect --format="{{.State.Status}}" cassandra 2>/dev/null || echo "missing")
      if [[ "$STATUS" != "running" ]]; then
        echo "Container is $STATUS — last 40 log lines:"
        sudo docker logs cassandra --tail 40 2>&1
        exit 1
      fi
      sudo docker exec cassandra nodetool status
    '
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
    echo "    Cleaning up resources that block VPC deletion..."
    _pre_delete_cleanup
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
    echo "    Waiting for deletion to complete..."
    aws cloudformation wait stack-delete-complete \
      --stack-name "$STACK_NAME" --region "$REGION"
    echo "    Done."
    exit 0
    ;;
esac

KEY_PAIR="$1"

# Strip .pem extension — AWS key pair names never include it.
# People often pass the filename (e.g. cassandra.pem) instead of the name (cassandra).
if [[ "$KEY_PAIR" == *.pem ]]; then
  STRIPPED="${KEY_PAIR%.pem}"
  echo "    Note: stripping .pem extension from key pair name ('$KEY_PAIR' → '$STRIPPED')"
  KEY_PAIR="$STRIPPED"
fi

echo "==> Detecting your public IP..."
MY_IP=$(curl -fsSL https://checkip.amazonaws.com | tr -d '[:space:]')
if [[ ! "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: could not detect public IP (got: '$MY_IP')"; exit 1
fi
ALLOWED_CIDR="${MY_IP}/32"
echo "    Restricting SSH + CQL to ${ALLOWED_CIDR}"

echo
echo "==> Pre-flight checks..."

# Verify AWS CLI is configured and can reach the region
if ! aws sts get-caller-identity --region "$REGION" --output text &>/dev/null; then
  echo "ERROR: AWS CLI is not configured or cannot reach $REGION."
  echo "       Run: aws configure"
  exit 1
fi
echo "    AWS credentials OK ✓"

# Verify the key pair exists in the target region
if ! aws ec2 describe-key-pairs \
    --key-names "$KEY_PAIR" \
    --region "$REGION" \
    --query 'KeyPairs[0].KeyPairName' \
    --output text &>/dev/null 2>&1; then
  echo "ERROR: EC2 key pair '$KEY_PAIR' not found in $REGION."
  echo
  echo "       Key pairs available in $REGION:"
  aws ec2 describe-key-pairs --region "$REGION" \
    --query 'KeyPairs[*].KeyPairName' --output table 2>/dev/null || echo "       (none found, or insufficient permissions)"
  echo
  echo "       Create one: AWS Console → EC2 → Key Pairs → Create key pair"
  echo "                   or: aws ec2 create-key-pair --key-name cassandra --region $REGION --query 'KeyMaterial' --output text > cassandra.pem"
  exit 1
fi
echo "    Key pair '$KEY_PAIR' found in $REGION ✓"

echo
echo "==> Deploying stack '$STACK_NAME' in $REGION"
echo "    (~5 min for CFN; another ~8-10 min for Cassandra ring to form)"

# --disable-rollback keeps the stack visible on failure so we can read the events.
# If this is a retry after a previous failure, we first need to delete the old stack.
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [[ "$STACK_STATUS" == "CREATE_FAILED" || "$STACK_STATUS" == "ROLLBACK_COMPLETE" ]]; then
  echo "    Found existing failed stack ($STACK_STATUS) — cleaning up before retry..."
  _pre_delete_cleanup
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
  echo "    Deleted. Proceeding with fresh deploy."
fi

# Start the deploy in the background so we can capture events if it fails
# before CloudFormation rolls back and deletes the stack.
aws cloudformation deploy \
  --template-file cloudformation.yaml \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --parameter-overrides \
      AllowedCidr="$ALLOWED_CIDR" \
      KeyPairName="$KEY_PAIR" \
  --no-fail-on-empty-changeset &
DEPLOY_PID=$!

# Poll for failure events while deploy is running, capture them before rollback wipes them.
CAPTURED_ERRORS=""
while kill -0 "$DEPLOY_PID" 2>/dev/null; do
  sleep 10
  ERRORS=$(aws cloudformation describe-stack-events \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
    --output table 2>/dev/null || true)
  if [[ -n "$ERRORS" && "$ERRORS" != *"---"*"---" ]]; then
    : # empty table, keep waiting
  elif [[ -n "$ERRORS" ]]; then
    CAPTURED_ERRORS="$ERRORS"
  fi
done

# Wait for the deploy process to exit and capture its exit code.
wait "$DEPLOY_PID" && DEPLOY_EXIT=0 || DEPLOY_EXIT=$?

if [[ "$DEPLOY_EXIT" -eq 0 ]]; then
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

else
  echo
  echo "ERROR: Stack deployment failed. Failed resources:"
  if [[ -n "$CAPTURED_ERRORS" ]]; then
    echo "$CAPTURED_ERRORS"
  else
    # Stack may already be rolled back — try anyway.
    aws cloudformation describe-stack-events \
      --stack-name "$STACK_NAME" --region "$REGION" \
      --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
      --output table 2>/dev/null || echo "    (stack already deleted — check CloudFormation console)"
  fi
  echo
  echo "    Re-run this script to try again once the rollback completes."
  exit 1
fi
