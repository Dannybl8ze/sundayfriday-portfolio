<#
  Deploys the portfolio to AWS (EC2 + Nginx + Bedrock chat backend).
  Safe to re-run: existing resources are reused, and on re-runs the new code is
  pushed to the running instance via SSM.

  Usage (from the project root):
    powershell -ExecutionPolicy Bypass -File deploy\deploy.ps1
#>
param(
  [string]$Region = 'us-east-1',
  [string]$Name = 'portfolio',
  [string]$InstanceType = 't3.micro',
  [string]$AlertEmail = 'sdfridaysd@gmail.com',
  [int]$BudgetUsd = 20
)
$ErrorActionPreference = 'Continue'
$env:PYTHONUTF8 = '1'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $env:TEMP "portfolio-deploy"
New-Item -ItemType Directory -Force $tmp | Out-Null

$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws) { $aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe' }

function Aws {
  $out = & $aws @args --region $Region --output text
  if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') failed" }
  return $out
}
function TryAws {
  $out = & $aws @args --region $Region --output text 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  return $out
}
function Write-Json($file, $obj) {
  $path = Join-Path $tmp $file
  [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $obj -Depth 10))
  return "file://$($path -replace '\\','/')"
}
function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

Step 'Checking credentials'
$account = Aws sts get-caller-identity --query Account
Write-Host "Account $account, region $Region"

# ---------- S3 bucket for the deploy bundle ----------
$bucket = "$Name-deploy-$account-$Region"
Step "S3 bucket $bucket"
if (-not (TryAws s3api head-bucket --bucket $bucket)) {
  if ($LASTEXITCODE -ne 0) {
    if ($Region -eq 'us-east-1') { Aws s3api create-bucket --bucket $bucket | Out-Null }
    else { Aws s3api create-bucket --bucket $bucket --create-bucket-configuration LocationConstraint=$Region | Out-Null }
    Aws s3api put-public-access-block --bucket $bucket --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' | Out-Null
  }
}

Step 'Uploading site bundle'
$bundle = Join-Path $tmp 'bundle.tgz'
Push-Location $root
tar -czf $bundle --exclude=__pycache__ --exclude=.vercel --exclude=".env*" --exclude=.gitignore --exclude=.vercelignore --exclude=vercel.json site server deploy
Pop-Location
if ($LASTEXITCODE -ne 0) { throw 'tar failed' }
Aws s3 cp $bundle "s3://$bucket/bundle.tgz" | Out-Null

# ---------- IAM role for the instance ----------
$role = "$Name-ec2-role"
Step "IAM role $role"
if (-not (TryAws iam get-role --role-name $role)) {
  $trust = Write-Json 'trust.json' @{
    Version = '2012-10-17'
    Statement = @(@{ Effect = 'Allow'; Principal = @{ Service = 'ec2.amazonaws.com' }; Action = 'sts:AssumeRole' })
  }
  Aws iam create-role --role-name $role --assume-role-policy-document $trust | Out-Null
  Aws iam attach-role-policy --role-name $role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore | Out-Null
}
$policy = Write-Json 'policy.json' @{
  Version = '2012-10-17'
  Statement = @(
    @{ Effect = 'Allow'; Action = @('bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream'); Resource = '*' },
    @{ Effect = 'Allow'; Action = 's3:GetObject'; Resource = "arn:aws:s3:::$bucket/*" }
  )
}
Aws iam put-role-policy --role-name $role --policy-name "$Name-app" --policy-document $policy | Out-Null
if (-not (TryAws iam get-instance-profile --instance-profile-name $role)) {
  Aws iam create-instance-profile --instance-profile-name $role | Out-Null
  Aws iam add-role-to-instance-profile --instance-profile-name $role --role-name $role | Out-Null
  Write-Host 'Waiting for the instance profile to propagate...'
  Start-Sleep -Seconds 15
}

# ---------- Existing instance? ----------
$instanceId = TryAws ec2 describe-instances --filters "Name=tag:Name,Values=$Name" "Name=instance-state-name,Values=pending,running,stopped" --query 'Reservations[0].Instances[0].InstanceId'
if ($instanceId -eq 'None') { $instanceId = $null }

if (-not $instanceId) {
  # ---------- Security group ----------
  Step 'Security group (HTTP only, admin via SSM, no SSH)'
  $vpc = Aws ec2 describe-vpcs --filters 'Name=isDefault,Values=true' --query 'Vpcs[0].VpcId'
  $sg = TryAws ec2 describe-security-groups --filters "Name=group-name,Values=$Name-web" "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[0].GroupId'
  if (-not $sg -or $sg -eq 'None') {
    $sg = Aws ec2 create-security-group --group-name "$Name-web" --description 'Portfolio web (HTTP/HTTPS)' --vpc-id $vpc --query GroupId
    Aws ec2 authorize-security-group-ingress --group-id $sg --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}],Ipv6Ranges=[{CidrIpv6=::/0}]' 'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}],Ipv6Ranges=[{CidrIpv6=::/0}]' | Out-Null
  }

  # ---------- Launch ----------
  Step "Launching $InstanceType (Amazon Linux 2023)"
  $ami = Aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query 'Parameters[0].Value'
  $userData = Join-Path $tmp 'user-data.sh'
  $ud = @"
#!/bin/bash
set -eux
mkdir -p /root/portfolio && cd /root/portfolio
aws s3 cp s3://$bucket/bundle.tgz bundle.tgz --region $Region
tar -xzf bundle.tgz deploy/install.sh
sed -i 's/\r$//' deploy/install.sh
bash deploy/install.sh $bucket
"@
  [IO.File]::WriteAllText($userData, ($ud -replace "`r`n", "`n"))
  $instanceId = Aws ec2 run-instances --image-id $ami --instance-type $InstanceType `
    --iam-instance-profile Name=$role --security-group-ids $sg `
    --user-data "file://$($userData -replace '\\','/')" `
    --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' `
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=8,VolumeType=gp3,Encrypted=true}' `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Name}]" `
    --query 'Instances[0].InstanceId'
  Write-Host "Instance $instanceId. Waiting until it is running..."
  Aws ec2 wait instance-running --instance-ids $instanceId | Out-Null
  $fresh = $true
} else {
  Step "Instance $instanceId exists"
  $state = Aws ec2 describe-instances --instance-ids $instanceId --query 'Reservations[0].Instances[0].State.Name'
  if ($state -eq 'stopped') {
    Aws ec2 start-instances --instance-ids $instanceId | Out-Null
    Aws ec2 wait instance-running --instance-ids $instanceId | Out-Null
  }
  $fresh = $false
}

# ---------- Elastic IP (stable address) ----------
Step 'Elastic IP'
$eip = TryAws ec2 describe-addresses --filters "Name=tag:Name,Values=$Name" --query 'Addresses[0].[AllocationId,PublicIp]'
if (-not $eip -or $eip -match '^None') {
  $alloc = Aws ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$Name}]" --query AllocationId
} else { $alloc = ($eip -split '\s+')[0] }
Aws ec2 associate-address --instance-id $instanceId --allocation-id $alloc --allow-reassociation | Out-Null
$ip = Aws ec2 describe-addresses --allocation-ids $alloc --query 'Addresses[0].PublicIp'

# ---------- Push code on re-runs ----------
if (-not $fresh) {
  Step 'Updating code on the instance via SSM'
  $params = Write-Json 'ssm.json' @{ commands = @(
    "cd /root/portfolio && aws s3 cp s3://$bucket/bundle.tgz bundle.tgz --region $Region",
    'tar -xzf bundle.tgz deploy/install.sh && sed -i ''s/\r$//'' deploy/install.sh',
    "bash deploy/install.sh $bucket"
  ) }
  $cmd = Aws ssm send-command --instance-ids $instanceId --document-name AWS-RunShellScript --parameters $params --query Command.CommandId
  TryAws ssm wait command-executed --command-id $cmd --instance-id $instanceId | Out-Null
  Aws ssm get-command-invocation --command-id $cmd --instance-id $instanceId --query Status
}

# ---------- Budget alert ----------
Step "Monthly budget alert at `$$BudgetUsd -> $AlertEmail"
if (-not (TryAws budgets describe-budget --account-id $account --budget-name "$Name-monthly")) {
  $budget = Write-Json 'budget.json' @{
    BudgetName = "$Name-monthly"; BudgetType = 'COST'; TimeUnit = 'MONTHLY'
    BudgetLimit = @{ Amount = "$BudgetUsd"; Unit = 'USD' }
  }
  $notes = Write-Json 'notify.json' @(
    @{ Notification = @{ NotificationType = 'ACTUAL'; ComparisonOperator = 'GREATER_THAN'; Threshold = 80; ThresholdType = 'PERCENTAGE' }
       Subscribers = @(@{ SubscriptionType = 'EMAIL'; Address = $AlertEmail }) },
    @{ Notification = @{ NotificationType = 'FORECASTED'; ComparisonOperator = 'GREATER_THAN'; Threshold = 100; ThresholdType = 'PERCENTAGE' }
       Subscribers = @(@{ SubscriptionType = 'EMAIL'; Address = $AlertEmail }) }
  )
  Aws budgets create-budget --account-id $account --budget $budget --notifications-with-subscribers $notes | Out-Null
}

Step 'Done'
Write-Host "Site: http://$ip" -ForegroundColor Green
if ($fresh) { Write-Host 'First boot installs packages; give it 2-4 minutes before the site responds.' }
