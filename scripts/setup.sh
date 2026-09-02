#!/usr/bin/env bash
# End-to-end bring-up. Usage:
#   ./scripts/setup.sh --profile personal --github-repo you/lucidity [--region ap-south-1] [--name lucidity] [--yes]
#   ./scripts/setup.sh --profile personal --destroy
set -euo pipefail

REGION="ap-south-1"
NAME="lucidity"
GITHUB_REPO=""
PROFILE=""
AUTO=""
DESTROY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)     PROFILE="$2"; shift 2 ;;
    --region)      REGION="$2"; shift 2 ;;
    --name)        NAME="$2"; shift 2 ;;
    --github-repo) GITHUB_REPO="$2"; shift 2 ;;
    --yes)         AUTO="-auto-approve"; shift ;;
    --destroy)     DESTROY=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$PROFILE" ]] || { echo "required: --profile <aws-profile>" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AWS_PROFILE="$PROFILE"

for tool in aws terraform kubectl helm docker; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IDENTITY=$(aws sts get-caller-identity --query Arn --output text)

# ---------------------------------------------------------------- destroy ---
if [[ -n "$DESTROY" ]]; then
  echo ">>> DESTROY against account $ACCOUNT_ID ($IDENTITY)"
  read -rp "Type the account id to confirm: " CONFIRM
  [[ "$CONFIRM" == "$ACCOUNT_ID" ]] || { echo "mismatch, aborting"; exit 1; }
  helm uninstall dashboards -n hello || true
  helm uninstall hello-world -n hello --wait || true      # removes the ALB
  for f in "$ROOT"/kubernetes/*.yaml; do
    sed "s/lucidity/${NAME}/g" "$f" | kubectl delete -f - || true
  done
  terraform -chdir="$ROOT/terraform/02-platform" destroy
  terraform -chdir="$ROOT/terraform/01-infra" destroy
  echo "State bucket kept on purpose (prevent_destroy). Done."
  exit 0
fi

# ----------------------------------------------------------------- checks ---
MY_IP=$(curl -sm 10 https://checkip.amazonaws.com)
[[ -n "$GITHUB_REPO" ]] || echo "WARN: no --github-repo; CI role will trust a placeholder until you re-apply."
GITHUB_REPO="${GITHUB_REPO:-CHANGEME/lucidity}"

cat <<EOF

  account   : $ACCOUNT_ID
  identity  : $IDENTITY
  region    : $REGION
  name      : $NAME
  your ip   : $MY_IP (only this IP may reach the EKS API)
  github    : $GITHUB_REPO

EOF
read -rp "Proceed? [y/N] " OK
[[ "$OK" == "y" || "$OK" == "Y" ]] || exit 1

# ------------------------------------------------------- generate configs ---
cat > "$ROOT/terraform/00-bootstrap/terraform.tfvars" <<EOF
aws_account_id = "$ACCOUNT_ID"
region         = "$REGION"
EOF

cat > "$ROOT/terraform/01-infra/terraform.tfvars" <<EOF
aws_account_id = "$ACCOUNT_ID"
region         = "$REGION"
name           = "$NAME"
admin_cidrs    = ["$MY_IP/32"]
github_repo    = "$GITHUB_REPO"
EOF

cat > "$ROOT/terraform/02-platform/terraform.tfvars" <<EOF
aws_account_id = "$ACCOUNT_ID"
region         = "$REGION"
cluster_name   = "$NAME"
EOF

# -------------------------------------------------------------- terraform ---
echo ">>> 00-bootstrap: state bucket"
terraform -chdir="$ROOT/terraform/00-bootstrap" init -input=false
terraform -chdir="$ROOT/terraform/00-bootstrap" apply $AUTO
BUCKET=$(terraform -chdir="$ROOT/terraform/00-bootstrap" output -raw state_bucket)

for stack in 01-infra 02-platform; do
  printf 'bucket = "%s"\nregion = "%s"\n' "$BUCKET" "$REGION" \
    > "$ROOT/terraform/$stack/backend.hcl"
done

echo ">>> 01-infra: VPC + EKS + ECR + CI role (~15 min)"
terraform -chdir="$ROOT/terraform/01-infra" init -input=false -backend-config=backend.hcl
terraform -chdir="$ROOT/terraform/01-infra" apply $AUTO

aws eks update-kubeconfig --name "$NAME" --region "$REGION" --alias "$NAME"

echo ">>> 02-platform: Karpenter + LB controller + monitoring (~10 min)"
terraform -chdir="$ROOT/terraform/02-platform" init -input=false -backend-config=backend.hcl
terraform -chdir="$ROOT/terraform/02-platform" apply $AUTO

# ---------------------------------------------------------- k8s manifests ---
# Repo YAML uses the default name "lucidity"; rendered for the chosen name.
echo ">>> k8s manifests (NodePool, EC2NodeClass, namespace)"
for f in "$ROOT"/kubernetes/*.yaml; do
  sed "s/lucidity/${NAME}/g" "$f" | kubectl apply -f -
done

# ------------------------------------------------------- first image+deploy -
echo ">>> first image + deploy"
ECR=$(terraform -chdir="$ROOT/terraform/01-infra" output -raw ecr_repository_url)
TAG=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%s)
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ECR%%/*}"
docker build -t "$ECR:$TAG" "$ROOT/app"
docker push "$ECR:$TAG"
helm upgrade --install hello-world "$ROOT/chart/hello-world" \
  --namespace hello \
  --set image.repository="$ECR" --set image.tag="$TAG" \
  --wait --timeout 5m
helm upgrade --install dashboards "$ROOT/chart/grafana" --namespace hello --wait

# ------------------------------------------------------------------ verify --
echo ">>> waiting for ALB (~2 min)"
for _ in $(seq 1 30); do
  URL=$(kubectl get ingress -n hello hello-world \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$URL" ]] && break
  sleep 10
done

cat <<EOF

Done.
  app       : curl http://${URL:-<pending - kubectl get ingress -n hello>}/
  grafana   : kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
              admin / \$(terraform -chdir=terraform/02-platform output -raw grafana_admin_password)
  ci setup  : GitHub repo variable AWS_CI_ROLE_ARN = $(terraform -chdir="$ROOT/terraform/01-infra" output -raw ci_role_arn)
EOF
