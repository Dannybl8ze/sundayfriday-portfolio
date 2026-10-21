#!/bin/bash
# Runs on the EC2 instance (Amazon Linux 2023): installs/updates the site from S3.
# Usage: install.sh <bucket>
set -euxo pipefail
BUCKET="$1"

dnf install -y nginx python3.11 python3.11-pip tar
python3.11 -c "import boto3" 2>/dev/null || python3.11 -m pip install --quiet boto3
id portfolio &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin portfolio

rm -rf /tmp/portfolio-bundle && mkdir -p /tmp/portfolio-bundle
aws s3 cp "s3://${BUCKET}/bundle.tgz" /tmp/portfolio-bundle/bundle.tgz
tar -xzf /tmp/portfolio-bundle/bundle.tgz -C /tmp/portfolio-bundle
# Bundle is built on Windows: strip any CRLF line endings
find /tmp/portfolio-bundle -type f \( -name '*.sh' -o -name '*.conf' -o -name '*.service' -o -name '*.py' \) -exec sed -i 's/\r$//' {} +

mkdir -p /opt/portfolio
rm -rf /opt/portfolio/site /opt/portfolio/server
cp -r /tmp/portfolio-bundle/site /tmp/portfolio-bundle/server /opt/portfolio/
chmod -R a+rX /opt/portfolio

cp /tmp/portfolio-bundle/deploy/nginx.conf /etc/nginx/nginx.conf
cp /tmp/portfolio-bundle/deploy/portfolio-chat.service /etc/systemd/system/portfolio-chat.service
nginx -t

systemctl daemon-reload
systemctl enable nginx portfolio-chat
systemctl restart portfolio-chat nginx
