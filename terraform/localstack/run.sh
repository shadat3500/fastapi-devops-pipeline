#!/usr/bin/env bash
# Exercise the Terraform code end to end against LocalStack and save evidence.
#
# Usage: terraform/localstack/run.sh [plan|apply|destroy]   (default: apply)
#   plan     bootstrap state bucket, init, fmt/validate, plan staging
#   apply    plan + apply staging, show resources, then plan production with the same code
#   destroy  destroy staging
#
# Requires: terraform >= 1.10, tflocal (pip: terraform-local), awslocal (pip: awscli-local),
#           LocalStack running on 127.0.0.1:4566 (see docker-compose.yml next to this file).
# Output is also written to docs/evidence/terraform-<action>.log.
set -euo pipefail

ACTION="${1:-apply}"
case "$ACTION" in plan|apply|destroy) ;; -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown action: $ACTION" >&2; exit 64 ;; esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${ROOT}/terraform"
EVIDENCE="${ROOT}/docs/evidence/terraform-${ACTION}.log"
mkdir -p "$(dirname "$EVIDENCE")"
exec > >(tee "$EVIDENCE") 2>&1

for bin in terraform tflocal awslocal curl; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done

step() { printf '\n\033[1m$ %s\033[0m\n' "$*"; "$@"; }

curl -fsS localhost:4566/_localstack/health >/dev/null \
  || { echo "LocalStack is not reachable on localhost:4566" >&2; exit 1; }

export AWS_DEFAULT_REGION=us-east-1

if [[ "$ACTION" == "destroy" ]]; then
  cd "$TF_DIR"
  step tflocal init -input=false -reconfigure -backend-config=envs/staging.backend.hcl
  step tflocal destroy -input=false -auto-approve -var-file=envs/staging.tfvars -var-file=envs/localstack.tfvars
  exit 0
fi

echo "##### 0. Bootstrap remote state bucket #####"
cd "${TF_DIR}/bootstrap"
step tflocal init -input=false
step tflocal apply -input=false -auto-approve
step awslocal s3api get-bucket-versioning --bucket devops-app-tfstate

cd "$TF_DIR"
echo; echo "##### 1. Static checks #####"
step terraform fmt -check -recursive
step tflocal init -input=false -reconfigure -backend-config=envs/staging.backend.hcl
step tflocal validate

echo; echo "##### 2. Plan: staging #####"
step tflocal plan -input=false -var-file=envs/staging.tfvars -var-file=envs/localstack.tfvars -out=staging.tfplan

if [[ "$ACTION" == "apply" ]]; then
  echo; echo "##### 3. Apply: staging #####"
  step tflocal apply -input=false staging.tfplan
  step tflocal output
  echo; echo "##### 4. Resources exist + state is remote and locked via S3 #####"
  # JMESPath uses backticks for literals; they must not be expanded by the shell.
  # shellcheck disable=SC2016
  step awslocal ec2 describe-instances --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`]|[0].Value]' --output table
  step awslocal ec2 describe-security-groups --filters Name=group-name,Values=devops-app-staging-sg --query 'SecurityGroups[].IpPermissions' --output json
  step awslocal logs describe-log-groups --query 'logGroups[].[logGroupName,retentionInDays]' --output table
  # shellcheck disable=SC2016
  step awslocal iam list-roles --query 'Roles[?starts_with(RoleName, `devops-app`)].RoleName' --output table
  step awslocal s3 ls s3://devops-app-tfstate --recursive

  # Production reuses the account-wide OIDC provider created by staging, so it's
  # planned after staging exists.
  echo; echo "##### 5. Same code, production variables + separate state key #####"
  step tflocal init -input=false -reconfigure -backend-config=envs/production.backend.hcl
  step tflocal plan -input=false -var-file=envs/production.tfvars -var-file=envs/localstack.tfvars
fi
rm -f staging.tfplan

echo; echo "Evidence written to ${EVIDENCE}"
