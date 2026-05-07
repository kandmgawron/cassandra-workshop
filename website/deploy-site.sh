#!/usr/bin/env bash
# Deploy the Cassandra workshop site to S3 static website hosting.
#
# Usage:
#   ./deploy-site.sh [region]            Create bucket + upload (uses AWS account ID in name)
#   ./deploy-site.sh [region] --update   Re-upload index.html to existing bucket
#   ./deploy-site.sh [region] --url      Print the site URL for an existing bucket
#   ./deploy-site.sh [region] --delete   Delete the bucket and all content

set -euo pipefail
cd "$(dirname "$0")"

REGION="${1:-${AWS_REGION:-us-east-1}}"
CMD="${2:-}"

# Derive a stable, unique bucket name from the AWS account ID.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="cassandra-workshop-${ACCOUNT_ID}"
SITE_URL="http://${BUCKET}.s3-website-${REGION}.amazonaws.com"

case "$CMD" in
  --url)
    echo "$SITE_URL"
    exit 0
    ;;
  --delete)
    echo "==> Deleting bucket s3://$BUCKET"
    aws s3 rb "s3://$BUCKET" --force --region "$REGION"
    echo "    Done."
    exit 0
    ;;
  --update)
    echo "==> Uploading index.html to s3://$BUCKET"
    aws s3 cp index.html "s3://$BUCKET/index.html" \
      --content-type text/html \
      --cache-control "max-age=60" \
      --region "$REGION"
    echo "    Site updated: $SITE_URL"
    exit 0
    ;;
esac

# ── Full deploy ─────────────────────────────────────────────────────────────

echo "==> Creating S3 bucket: $BUCKET (region: $REGION)"
if [ "$REGION" = "us-east-1" ]; then
  # us-east-1 doesn't accept a LocationConstraint
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION"
else
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi

echo "==> Enabling static website hosting"
aws s3api put-bucket-website \
  --bucket "$BUCKET" \
  --website-configuration '{
    "IndexDocument": {"Suffix": "index.html"},
    "ErrorDocument": {"Key": "index.html"}
  }' \
  --region "$REGION"

echo "==> Disabling Block Public Access (required for static website hosting)"
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false \
  --region "$REGION"

echo "==> Applying public read bucket policy"
aws s3api put-bucket-policy \
  --bucket "$BUCKET" \
  --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"PublicReadGetObject\",
      \"Effect\": \"Allow\",
      \"Principal\": \"*\",
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::${BUCKET}/*\"
    }]
  }" \
  --region "$REGION"

echo "==> Uploading index.html"
aws s3 cp index.html "s3://$BUCKET/index.html" \
  --content-type text/html \
  --cache-control "max-age=60" \
  --region "$REGION"

echo
echo "✅ Workshop site live at:"
echo "   $SITE_URL"
echo
echo "To update content:  ./deploy-site.sh $REGION --update"
echo "To delete:          ./deploy-site.sh $REGION --delete"
