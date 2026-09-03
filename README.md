## Repository layout

| Path | What it is |
|---|---|
| `app/` | Go service: `/` → "Hello World", `/healthz`, `/metrics` (Prometheus) |
| `chart/hello-world/` | App chart: Deployment, Service, Ingress (ALB), HPA, PDB + its ServiceMonitor and alert rules |
| `chart/grafana/` | Grafana dashboards as code (ConfigMaps the Grafana sidecar auto-imports) |
| `terraform/00-bootstrap/` | S3 bucket for Terraform state (local state itself — see trade-offs) |
| `terraform/01-infra/` | VPC, EKS cluster, ECR repo, GitHub-OIDC CI role |
| `terraform/02-platform/` | Karpenter, AWS Load Balancer Controller, kube-prometheus-stack |
| `kubernetes/` | Karpenter NodePool/EC2NodeClass and the app namespace (plain `kubectl apply`) |
| `.github/workflows/` | `app` (test → build → push → deploy), `terraform` (fmt + validate) |
| `pictures` | Architecture Diagrams and things done in the process

## Prerequisites

- AWS account + a CLI profile for it (`aws configure --profile personal`), verified
  with `aws sts get-caller-identity`
- `terraform` (pinned by `.terraform-version`, use tfenv), `kubectl`, `helm`, `docker`

## Bringing infra up

One command (generates tfvars/backend config, applies all stacks in order,
templates the kubernetes manifests, builds and deploys the first image):

```bash
./scripts/setup.sh --profile personal --github-repo <you>/lucidity
./scripts/setup.sh --profile personal --destroy
```

Or step by step, which is the same thing spelled out:

```bash
export AWS_PROFILE=personal
aws sts get-caller-identity      

# 1. State bucket
cd terraform/00-bootstrap
cp terraform.tfvars.example terraform.tfvars  
terraform init && terraform apply
terraform output -raw backend_hcl             

# 2. VPC + EKS + ECR + CI role 
cd ../01-infra
cp terraform.tfvars.example terraform.tfvars   
terraform init -backend-config=backend.hcl && terraform apply
aws eks update-kubeconfig --name lucidity --region ap-south-1 --alias lucidity

# 3. Karpenter + LB controller + monitoring 
cd ../02-platform
cp terraform.tfvars.example terraform.tfvars   
terraform init -backend-config=backend.hcl && terraform apply

# 4. Node pool + app namespace
kubectl apply -f ../../kubernetes/

# 5. First image + deploy (afterwards CI does this on every push to main)
ECR=$(cd ../01-infra && terraform output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR%%/*}"
docker build -t "$ECR:manual-1" app/ && docker push "$ECR:manual-1"
helm upgrade --install hello-world chart/hello-world -n hello \
  --set image.repository="$ECR" --set image.tag=manual-1 --wait
helm upgrade --install dashboards chart/grafana -n hello --wait

# 6. Endpoint of the application
kubectl get ingress -n hello
curl http://<address>/
```

### Monitoring

```bash
# user: admin, password:
terraform -chdir=terraform/02-platform output -raw grafana_admin_password
```

The **Hello World Service** dashboard (requests/sec, p95 latency, ready pods) is
auto-imported from the chart's ConfigMap. Prometheus discovers the app through the
chart's ServiceMonitor. Three alerts ship with the chart:

| Alert | Fires when | Severity |
|---|---|---|
| `HelloWorldAllTargetsMissing` | no pod scraped for 5 min (deployment gone) | critical |
| `HelloWorldTargetDown` | a pod unreachable for 5 min | warning |
| `HelloWorldHighLatency` | p95 > 500 ms for 10 min | warning |

Alertmanager runs but routes to a null receiver; wiring Slack/PagerDuty is a
values change (`alertmanager.config`) — deliberately left out of a demo repo so
no webhook URL lives in git.

## CI/CD

`app` workflow: PRs run tests + helm lint. Pushes to `main` additionally build the
image, push to ECR tagged with the git SHA, and `helm upgrade` the cluster.

`terraform` workflow: fmt + validate on every PR touching `terraform/`.

## Design decisions & trade-offs
1. Karpenter over cluster-autoscaler for node scaling: picks instance size per
  workload, consolidates underused nodes, handles spot interruptions, and gives a
  richer feature set if we want extra customizations later
2. Workload/platform node separation. The Karpenter NodePool is tainted
  (`app=true:NoSchedule`) and the app deployment opts in via toleration +
  `nodeSelector: role: app` — app pods run only on Karpenter capacity, and
  platform pods (monitoring, controllers) keep the system node group to
  themselves, so critical platform components keep running even if app
  workloads misbehave
3. High availability and scalability : the application runs 2 minimum replicas
   spread across two AZs and HPA is configured to scale out with traffic ; similarly
   one NAT gateway per AZ is set up so an AZ failure doesn't take down egress
   for the other
4. Terraform applies have been made manual for now instead of adding it to ci , due to
   the higher level of permission needed to run tf apply . With a team I would move
   to plan-on-PR with a gated apply
5. IRSA for in-cluster AWS access (LB controller and Karpenter):
  each controller's ServiceAccount is bound to an IAM role via the cluster's OIDC
  provider — short-lived creds, no keys in the cluster
6. GitOps : currently helm handles the sync to the cluster , but in production we
   can use a HelmRelease (Flux) to handle the state sync into the cluster for better
   visibility and rollbacks
7. EKS CIDR restriction : at the start of the project I had just added my IP to
   access EKS , but when CI needs to run helm commands from GitHub hosted runners
   I had to allow a wider range ; a self hosted runner inside the VPC would let us
   keep the endpoint restricted
8. Terraform setup : Split into three stacks (00-bootstrap , 01-infra , 02-platform) 
   by lifecycle instead of one big stack , so destroys stay clean and platform changes 
   dont touch the vpc/cluster . Kept it flat without modules/ and envs/ dirs since 
   there is only one environment and single use infra , wrapper modules would just add 
   indirection here — the registry modules (vpc/eks/karpenter/iam) do the heavy 
   lifting . Everything account/region specific comes through tfvars and backend 
   config (gitignored) so moving to another account is a config change not a code 
   change.
9. Multi Arch Docker Images : Images built locally on my laptop come out as arm64 and the 
   github runners build amd64 , and karpenter nodes can be either arch depending on 
   whats cheapest on spot . So the pipeline builds a multi arch image with buildx 
   (amd64 + arm64) and kubelet pulls the matching variant from the manifest.
10. Ingress : Used same ingress group (`alb.ingress.kubernetes.io/group.name`) for 
    the app and grafana , so both share a single ALB with path based routing 
    (`/` → app , `/grafana` → grafana) instead of paying for one LB per service . 
    Prometheus is deliberately not exposed on the ALB since it has no authentication, 
    access is port-forward only

## Extending this

**Add a second microservice**
1. New ECR repo: copy the resource in `terraform/01-infra/ecr.tf`, apply.
2. Copy `chart/hello-world/` → `chart/<name>/`; edit the alert expressions and
   dashboard queries (they reference the service's own metric names).
3. Copy the deploy job in `.github/workflows/app.yml` (or matrix it).
   Monitoring needs no central change — the new chart's ServiceMonitor, alerts and
   dashboard are discovered automatically.

**Add a second environment (staging/prod)**
1. Per env: its own `terraform.tfvars` (name, CIDRs, account id) and its own
   `backend.hcl` key, e.g. `-backend-config="key=lucidity/staging-01-infra.tfstate"`.
2. `kubernetes/karpenter.yaml` hardcodes the cluster name in the role name and discovery
   tag (the price of keeping it as plain YAML) — copy it per env, or template it
   if environments multiply.

**Move to a different AWS account/region**
Everything account- or region-specific enters through `terraform.tfvars` /
`backend.hcl` (gitignored) and the `env:` block at the top of the app workflow.
No `.tf` file changes; `allowed_account_ids` guards each stack against running
in the wrong account.


## Known limitations

- Plain HTTP on the ALB — no ACM cert/HTTPS (needs a domain , havent added this).
- Karpenter controller and Grafana/Prometheus run single-replica in here.
- Alertmanager has no real receiver configured for now.
- The first deploy is manual (CI deploys from the second push onward , pipeline is running upgrade need to do a init first).

## Destroy Flow

```bash
helm uninstall dashboards -n hello
helm uninstall hello-world -n hello        
kubectl delete -f kubernetes/                     
terraform -chdir=terraform/02-platform destroy
terraform -chdir=terraform/01-infra destroy
```