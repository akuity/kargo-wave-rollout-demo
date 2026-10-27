# Kargo wave rollout demo

A runnable reference for rolling releases out region by region with Kargo on the Akuity
Platform. It covers a Kubernetes service on many production clusters and a Lambda
function in several AWS regions. Each prod Stage verifies the release against metrics,
and a Stage whose verification fails rolls itself back with no human action. QA signs
off on what reaches production, and a small set of platform-owned building blocks is
shared by every team.

```text
web-service (Kubernetes, 11 Stages)
dev ──▶ qa ──▶ prod-wave1 ──▶ prod-wave2-a ─┐
 auto   QA      QA (canary)   prod-wave2-b ─┼──▶ prod-wave3-a … prod-wave3-e
                              prod-wave2-c ─┘    (all of wave 2 must verify first)

lambda-service (Lambda, 5 Stages)
fn-dev ──▶ fn-qa ──▶ fn-prod-eu-west-1 ──▶ fn-prod-us-east-1
 auto      QA        QA (canary region)  └▶ fn-prod-ap-southeast-2
```

- **One Warehouse per service** watches its registry (and, for the Kubernetes service,
  its manifests in git). Each new build becomes Freight.
- **One Stage per environment, cluster or region.** A Stage lists where its Freight
  comes from, its verification, and the platform task it runs.
- **Waves**: each wave takes a release only after the wave before it verified it. A bad
  release caught in the canary never goes further.
- **Verification**: Kubernetes Stages check error rate and p95 latency from Prometheus.
  Lambda Stages check the function's error rate.
- **Automatic rollback**: `autoRollback` on every prod Stage re-promotes the last
  verified Freight when a promotion or its verification fails.
- **Git** (Kubernetes): a Kustomize base plus one overlay per Stage. Kargo changes only
  the image tag, builds the overlay and pushes the result to a `rendered/<stage>`
  branch that Argo CD syncs. Kargo never commits to `main`.

To keep it runnable on a laptop, a few things are stand-ins:

- The nine prod "clusters" are nine namespaces in one kind cluster.
- AWS is a small simulator (`sim/lambda`) that plays the Lambda API and CloudWatch.

Promotion, verification, gating and rollback behave as they would for real. The
sections below say what to swap for production.

## What the platform team owns, and what teams own

| Owner | What | Where |
| --- | --- | --- |
| Platform | `deploy-k8s`: render a team's overlay to its rendered branch and sync Argo CD | `platform/promotion-tasks.yaml` |
| Platform | `deploy-lambda`: point a function's `live` alias at a new version, per region | `platform/promotion-tasks.yaml` |
| Platform | The checks prod Stages run and their thresholds: `ingress-error-rate`, `ingress-latency-p95`, `lambda-error-rate` | `platform/analysis-templates.yaml` |
| Platform | Cluster add-ons (ingress controller, metrics). Usually already exist | `platform/addons.tpl.yaml` |
| Team | Manifests: a Kustomize base and an overlay per Stage | `teams/web-service/app/` |
| Team | Its Kargo project: Warehouse, Stages, promotion policy, who may promote | `teams/*/kargo/` |

The platform files are cluster-scoped `ClusterPromotionTask` and `ClusterAnalysisTemplate`
resources: one copy, used by every project. A team's Stage names the task and passes a few
values (repo, image, overlay path, or function and region). Changing how every service
deploys or what "healthy" means is one change in `platform/`.

Platform runs no bots and no per-team charts, and adds no controllers to workload clusters
beyond the Akuity agent.

## QA signoff

In both projects, the Stages that need a person are `qa` and the first prod wave or
region (`fn-qa` and `fn-prod-eu-west-1` for the Lambda). Every other Stage promotes on its
own. `teams/*/kargo/roles.tpl.yaml` maps those gates to SSO groups:

- `qa` (group `qa-approvers`): read everything, promote to the two gate Stages only.
- `developer` (group `developers`): read everything, promote nothing.

A Kargo role is a ServiceAccount, Role and RoleBinding in the project namespace, mapped
to a group claim by annotation. That makes it plain YAML that lives in git with the rest
of the project. Group names are set in [`config.env`](config.env). This demo runs with SSO
off and logs in as `admin`, so the roles are created but nobody logs in through them.
With Okta (or any OIDC provider) connected to Kargo, they apply as written.

## The Lambda lane

The function ships as a container image, so its Warehouse subscribes to an image
registry like any other service. `deploy-lambda` points the function's `live` alias in
one region at the Freight's version, and `lambda-error-rate` reads Errors / Invocations
for that alias.

In this demo both calls go to `sim/lambda`, an in-cluster stand-in for the Lambda and
CloudWatch APIs. It decides how a version behaves from its tag: `bad-*` fails about 30%
of invocations, `slow-*` is slow, and anything else is healthy. `make functions` shows
where each alias points.

Against AWS you only change the two platform resources. The Stages, gates, verification
and rollback stay the same:

- **Deploy**: replace the `http` step in `deploy-lambda` with either:
  - `gha-dispatch-workflow`, calling the GitHub Actions workflow that already deploys the
    function, or
  - a custom step that runs the AWS CLI (`update-function-code`, `publish-version`,
    `update-alias`).
- **Verify**: point `lambda-error-rate` at CloudWatch (`examples/cloudwatch-lambda-analysis.yaml`)
  or at the metrics backend the Lambda metrics are shipped to
  (`examples/coralogix-analysis.yaml`).

## Where things are

| Path | What |
| --- | --- |
| `platform/` | Shared promotion tasks, verification templates, cluster add-ons |
| `teams/web-service/` | The Kubernetes service: manifests, Argo CD Application template, Kargo project |
| `teams/lambda-service/` | The Lambda function's Kargo project |
| `sim/lambda/` | The AWS stand-in. Not part of the pattern |
| `examples/` | Not applied: Coralogix and CloudWatch verification, Slack notifications |
| `scripts/`, `Makefile` | Build, drive and tear down the demo |

## Running it

What `make up` creates, all temporary and all removed by `make down`:

- a kind cluster on your local Docker (OrbStack by default)
- an Argo CD and a Kargo instance in your Akuity organization
- one self-hosted Kargo agent and one Argo CD agent in the kind cluster

Prerequisites:

- `akuity login` done, and an Akuity org you can create instances in (`ORG` in
  [`config.env`](config.env))
- a GitHub token that can push to this repo, exported as `GITHUB_TOKEN` or held in a
  `pass` entry named by `PAT_PASS_ENTRY`. Kargo uses it to push the `rendered/*`
  branches. Either a fine-grained token with Contents read/write on this repo only, or
  a classic token with the `public_repo` scope (enough for a public repo, but it can push
  to every public repo you can write to). The token is stored only in the temporary
  Kargo and Argo CD instances, which `make down` deletes
- tools: `kind`, `kubectl`, `kargo` (1.12.x), `akuity`, `jq`, `yq`, `envsubst`, `htpasswd`

If you run it from a fork, set `GIT_REPO` to the fork.

```bash
make up       # 25-35 min the first time; re-run to finish a partial build
make watch    # leave running in a second terminal
make ui       # in a third: app UIs on :8080, Prometheus on :9090
```

`make up` ends with every Stage of both services on `rollouts-demo:blue` and prints the
Kargo and Argo CD URLs. The Kargo login is `admin` with the password in
`.state/kargo-admin-password`.

- **One `kargo` CLI login.** The `kargo` CLI keeps a single login. Every target logs it
  in to the demo instance if it isn't already, which replaces your previous login.
- **One Freight per tag, per service.** Each image tag yields one Freight per service, so
  each scenario below uses a new tag. The
  [image](https://hub.docker.com/r/argoproj/rollouts-demo/tags) has `blue`, `green`,
  `yellow`, `orange`, `purple` and `red`, each also as `bad-*` (errors) and `slow-*`
  (latency).

| Target | What it does |
| --- | --- |
| `make status` / `make watch` | Every Stage's Freight, verification and health, for both services |
| `make release TAG=green [LANE=fn]` | New Freight for that tag, as if CI had just published it. `LANE=fn` releases the Lambda |
| `make promote STAGE=qa [TAG=green]` | Promote a release to a Stage, as QA would in the UI. `fn-*` Stages are the Lambda |
| `make functions` | Where each simulated Lambda alias points |
| `make ui` | Port-forwards for the Stage links in the Kargo UI |
| `make down` | Delete everything the demo created |

## Scenarios

Start each from the state the previous one leaves.

### 1. A bad release is caught in the canary and rolled back

```bash
make release TAG=bad-yellow
make promote STAGE=qa
make promote STAGE=prod-wave1
```

The error-rate check on `prod-wave1` fails, and Kargo re-promotes the previous release
on its own. Waves 2 and 3 never take `bad-yellow`, because wave 1 never verified it.
`dev` and `qa` do accept it, because they have no metric checks. Adding the same checks
to `qa` would catch it before prod.

From a test run (`bad-yellow` serves about 40% 500s):

| Time | Event |
| --- | --- |
| 0:00 | `bad-yellow` promoted to `prod-wave1` by a person |
| 0:20 | verification starts |
| 1:20 | error-rate check fails (two bad samples, one allowed) |
| 1:20 | Kargo creates the rollback Promotion (no actor) |
| 1:32 | `prod-wave1` is back on the previous release |

`slow-*` tags fail the same way through the latency check.

### 2. The fix rolls out in waves

```bash
make release TAG=green
make promote STAGE=qa
make promote STAGE=prod-wave1
```

The same canary that rejected `bad-yellow` passes `green`. The three wave 2 Stages then
start together. Wave 3 waits until all three have passed, and then all five start. In a
test run, the whole of prod went from canary to the last wave 3 Stage verified in about
7.5 minutes.

After a rollback, Kargo does not roll a Stage forward again until a person promotes
something. Someone decides the fix is ready.

### 3. The same thing for a Lambda

```bash
make release LANE=fn TAG=bad-orange
make promote STAGE=fn-qa
make promote STAGE=fn-prod-eu-west-1     # fails verification, rolls back to blue
make functions                           # eu-west-1 alias history shows both moves
make release LANE=fn TAG=orange
make promote STAGE=fn-qa
make promote STAGE=fn-prod-eu-west-1     # passes; us-east-1 and ap-southeast-2 follow
```

From a test run, as `make functions` shows it for `orders/eu-west-1`:

| Time | Event |
| --- | --- |
| 0:00 | `bad-orange` promoted to `fn-prod-eu-west-1` by a person: alias moves to v2 |
| 0:28 | error-rate check fails; Kargo creates the rollback Promotion (no actor) |
| 0:29 | alias moves to v3, the previous version again |
| 0:58 | `orange` promoted by a person: alias moves to v4, verification passes |
| 1:46 | `us-east-1` and `ap-southeast-2` move to `orange` on their own |
| 2:36 | `orange` verified in all three regions |

The other two regions stay on the previous version the whole time `bad-orange` is in the
canary.

### 4. Breaking a good release live

Promote a fresh good tag to `prod-wave1`. While it verifies, open the Stage's **App**
link (needs `make ui`) and turn up the error dial. The extra 500s fail verification, and
Kargo rolls the Stage back to the previous release.

### Things that look like bugs but aren't

- The first promotion to each Kubernetes Stage takes a few minutes to sync. Argo CD learns
  about the `rendered/<stage>` branch only after Kargo creates it. Later promotions sync in
  seconds.
- After an automatic rollback, Kargo does not auto-promote that Stage again until a person
  promotes something.
- Kargo does not auto-promote Freight that already failed on a Stage. Ship a new tag.
- Restarting the Lambda stand-in forgets every alias, since its state is in memory. Re-run
  `make up` to put the baseline back.

## Not covered here

- blocking Freight that someone has flagged as faulty
- Kosli or other audit records written from a promotion step
- Terraform and other non-Lambda targets (Kargo has `tf-plan`/`tf-apply` steps for those)
