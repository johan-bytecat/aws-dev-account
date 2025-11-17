#!/bin/bash

# Private Instance Setup Script
# This script sets up additional applications and services on the private instance
# Arguments: $1=SCRIPTS_BUCKET $2=DATA_BUCKET

SCRIPTS_BUCKET="$1"
DATA_BUCKET="$2"

echo "Setting up private instance applications..."

# Install additional useful packages
yum install -y htop tree wget curl git

# Set up Docker aliases for Podman (for easier transition)
cat >> /home/ec2-user/.bashrc << 'EOF'

# Podman aliases
alias docker=podman
alias docker-compose=podman-compose

# Useful aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
EOF

# Create application directory structure
mkdir -p /opt/applications/{web,api,workers}
mkdir -p /mnt/data/{uploads,exports,backups}
chown -R ec2-user:ec2-user /opt/applications
chown -R ec2-user:ec2-user /mnt/data

# Set up a simple web server container for testing
cat > /opt/applications/web/start-nginx.sh << 'EOF'
#!/bin/bash
# Start a simple nginx container for testing

podman run -d \
  --name test-web \
  -p 80:80 \
  -v /mnt/data/web:/usr/share/nginx/html:ro \
  nginx:latest

echo "Test web server started on port 80"
echo "Place files in /mnt/data/web/ to serve them"
EOF

chmod +x /opt/applications/web/start-nginx.sh

# Create a sample index.html
mkdir -p /mnt/data/web
cat > /mnt/data/web/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>DevCloud Private Instance</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .header { color: #333; }
        .info { background: #f0f0f0; padding: 20px; border-radius: 5px; }
    </style>
</head>
<body>
    <h1 class="header">DevCloud Private Instance</h1>
    <div class="info">
        <h2>System Information</h2>
        <p><strong>Hostname:</strong> <span id="hostname"></span></p>
        <p><strong>Status:</strong> Running</p>
        <p><strong>EFS Mount:</strong> /mnt/data</p>
        <p><strong>Container Platform:</strong> Podman</p>
    </div>
    
    <script>
        document.getElementById('hostname').textContent = window.location.hostname;
    </script>
</body>
</html>
EOF

# Set up log aggregation
cat > /usr/local/bin/aggregate-logs.sh << 'EOF'
#!/bin/bash
# Aggregate and upload application logs

SCRIPTS_BUCKET="$1"
DATA_BUCKET="$2"

if [ -z "$DATA_BUCKET" ]; then
    DATA_BUCKET=$(aws cloudformation describe-stacks --stack-name devcloud-infrastructure --region af-south-1 --query 'Stacks[0].Outputs[?OutputKey==`DataBucketName`].OutputValue' --output text)
fi

LOG_DIR="/var/log/applications"
ARCHIVE_NAME="logs-$(hostname)-$(date +%Y%m%d-%H%M%S).tar.gz"

# Create log archive
tar -czf /tmp/$ARCHIVE_NAME -C $LOG_DIR . 2>/dev/null

# Upload to S3
if [ -f /tmp/$ARCHIVE_NAME ]; then
    aws s3 cp /tmp/$ARCHIVE_NAME s3://$DATA_BUCKET/log-archives/
    rm /tmp/$ARCHIVE_NAME
    echo "Logs archived and uploaded to S3"
else
    echo "No logs to archive"
fi
EOF

chmod +x /usr/local/bin/aggregate-logs.sh

# Set up automated backups of EFS data
cat > /usr/local/bin/backup-efs.sh << 'EOF'
#!/bin/bash
# Backup EFS data to S3

DATA_BUCKET="$1"

if [ -z "$DATA_BUCKET" ]; then
    DATA_BUCKET=$(aws cloudformation describe-stacks --stack-name devcloud-infrastructure --region af-south-1 --query 'Stacks[0].Outputs[?OutputKey==`DataBucketName`].OutputValue' --output text)
fi

BACKUP_NAME="efs-backup-$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="/tmp/$BACKUP_NAME.tar.gz"

echo "Starting EFS backup..."

# Create backup
tar -czf $BACKUP_FILE -C /mnt/data . 2>/dev/null

if [ $? -eq 0 ]; then
    # Upload to S3
    aws s3 cp $BACKUP_FILE s3://$DATA_BUCKET/efs-backups/
    
    if [ $? -eq 0 ]; then
        echo "EFS backup completed: $BACKUP_NAME.tar.gz"
        rm $BACKUP_FILE
        
        # Keep only the last 7 days of backups
        aws s3 ls s3://$DATA_BUCKET/efs-backups/ | grep "efs-backup-" | sort -r | tail -n +8 | awk '{print $4}' | while read file; do
            aws s3 rm s3://$DATA_BUCKET/efs-backups/$file
        done
    else
        echo "Failed to upload backup to S3"
        rm $BACKUP_FILE
    fi
else
    echo "Failed to create backup"
fi
EOF

chmod +x /usr/local/bin/backup-efs.sh

# Schedule daily EFS backups (2 AM)
echo "0 2 * * * /usr/local/bin/backup-efs.sh $DATA_BUCKET" | crontab -u ec2-user -

# Set up container management helper script
cat > /usr/local/bin/manage-containers.sh << 'EOF'
#!/bin/bash
# Container management helper

case "$1" in
    "start-web")
        /opt/applications/web/start-nginx.sh
        ;;
    "stop-web")
        podman stop test-web
        podman rm test-web
        ;;
    "list")
        podman ps -a
        ;;
    "logs")
        if [ -n "$2" ]; then
            podman logs "$2"
        else
            echo "Usage: $0 logs <container_name>"
        fi
        ;;
    *)
        echo "Usage: $0 {start-web|stop-web|list|logs <container_name>}"
        ;;
esac
EOF

chmod +x /usr/local/bin/manage-containers.sh

echo "Private instance setup completed successfully!"

# Log completion
echo "$(date): Private instance setup completed" >> /var/log/setup.log
