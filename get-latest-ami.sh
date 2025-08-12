# Check if the AMI IDs are correct for af-south-1 region
aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-*" "Name=architecture,Values=x86_64" "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --region af-south-1 \
  --output text \
  --profile bytecatdev


echo "x86_64 AMI ID for Amazon Linux 2023 in af-south-1"

aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-*" "Name=architecture,Values=arm64" "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --region af-south-1 \
  --output text

echo "ARM64 AMI ID for Amazon Linux 2023 in af-south-1"
