# Kargo wave rollout demo

A runnable reference for rolling one release across many production clusters in waves
with Kargo on the Akuity Platform. Each prod Stage verifies the release against metrics,
and a Stage whose verification fails rolls itself back with no human action.

```text
dev ──▶ qa ──▶ prod-wave1 ──▶ prod-wave2-a ─┐
 auto   manual   manual       prod-wave2-b ─┼──▶ prod-wave3-a … prod-wave3-e
                (canary)      prod-wave2-c ─┘    (all of wave 2 must verify first)
```

- **One Warehouse** watches the image registry and this repo's `app/` directory. Each
  new build becomes Freight (image tag + manifest commit).
- **One Stage per environment or cluster**: 11 in all. Each Stage is about 15 lines: where its Freight
  comes from, its verification, and the shared `deploy` task.
- **Waves**: wave 2 takes a release only after the canary (`prod-wave1`) verified it, and
  wave 3 only after *every* wave 2 Stage verified it (`availabilityStrategy: All`). A bad
  release caught in the canary never reaches wave 2.
- **Verification**: every prod Stage checks error rate and p95 latency from Prometheus
  for its own host. See `examples/coralogix-analysis.yaml` for the same check against
  Coralogix.
- **Automatic rollback**: `autoRollback` on every prod Stage re-promotes the last
  verified Freight when a promotion or its verification fails.
- **Git**: manifests are a Kustomize base plus one overlay per Stage. Kargo changes only
  the image tag, builds the overlay, and pushes the result to a `rendered/<stage>`
  branch that Argo CD syncs. Kargo never commits to `main`.

To keep it runnable on a laptop, the nine prod "clusters" are nine namespaces in one kind
cluster. Promotion, verification, gating and rollback behave the same as with real
clusters: give each Argo CD Application a different destination and nothing in Kargo
changes.

## Where things are

| Path | What |
| --- | --- |
| `app/base`, `app/overlays/<stage>` | The service's manifests. `traffic.yaml` is synthetic load so the metrics always have data |
| `kargo/project.tpl.yaml` | Project and promotion policy: what auto-promotes, where `autoRollback` applies |
| `kargo/warehouse.tpl.yaml` | Image + git subscription |
| `kargo/stages.tpl.yaml` | The 11 Stages and their wave dependencies |
| `kargo/tasks.tpl.yaml` | The `deploy` PromotionTask every Stage runs |
| `kargo/analysis.tpl.yaml` | Error-rate and p95-latency verification |
| `argocd/` | One Application per Stage, plus ingress-nginx and Prometheus as add-ons |
| `examples/` | Not applied: a Coralogix AnalysisTemplate and Slack notifications |
| `scripts/`, `Makefile` | Build, drive and tear down the demo |

## Running it

What `make up` creates, all temporary and all removed by `make down`:

- a kind cluster on your local Docker (OrbStack by default)
- an Argo CD and a Kargo instance in your Akuity organization
- one self-hosted Kargo agent and one Argo CD agent in the kind cluster

Prerequisites:

- `akuity login` done, and an Akuity org you can create instances in (`ORG` in
  [`config.env`](config.env))
- a GitHub token with contents read/write on this repo, exported as `GITHUB_TOKEN` or held
  in a `pass` entry named by `PAT_PASS_ENTRY`. Kargo uses it to push the `rendered/*`
  branches
- tools: `kind`, `kubectl`, `kargo` (1.12.x), `akuity`, `jq`, `yq`, `envsubst`, `htpasswd`

If you run it from a fork, set `GIT_REPO` to the fork.

```bash
make up       # 20-30 min the first time; re-run to finish a partial build
make watch    # leave running in a second terminal
make ui       # in a third: app UIs on :8080, Prometheus on :9090
```

`make up` ends with every Stage on `rollouts-demo:blue` and prints the Kargo and Argo CD
URLs. The Kargo login is `admin` with the password in `.state/kargo-admin-password`.

- **One `kargo` CLI login.** The `kargo` CLI keeps a single login. Every target logs it
  in to the demo instance if it isn't already, which replaces your previous login.
- **One Freight per tag.** Each image tag yields one Freight, so each scenario below
  uses a new tag. The [image](https://hub.docker.com/r/argoproj/rollouts-demo/tags) has
  `blue`, `green`, `yellow`, `orange`, `purple` and `red`, each also as `bad-*` (returns
  500s) and `slow-*` (adds latency).

| Target | What it does |
| --- | --- |
| `make status` / `make watch` | Every Stage's Freight, verification and health |
| `make release TAG=green` | New Freight for that tag, as if CI had just published it. `dev` takes it on its own |
| `make promote STAGE=qa [TAG=green]` | Promote a release to a Stage, as QA would in the UI |
| `make ui` | Port-forwards for the Stage links in the Kargo UI |
| `make down` | Delete everything the demo created |

## Scenarios

Start each from the state the previous one leaves.

### 1. A good release rolls out in waves

```bash
make release TAG=green
```

`dev` deploys it. Promote it to `qa` and then `prod-wave1` from the Kargo UI (or `make
promote STAGE=qa`, then `STAGE=prod-wave1`). Then watch:

- `prod-wave1` verifies for about two minutes.
- The three wave 2 Stages start together once it passes.
- Wave 3 waits until all three wave 2 Stages have passed, then all five start.

### 2. A bad release is caught in the canary and rolled back

```bash
make release TAG=bad-yellow
make promote STAGE=qa
make promote STAGE=prod-wave1
```

The error-rate check on `prod-wave1` fails. Kargo re-promotes `green` to `prod-wave1` on
its own. Waves 2 and 3 never take `bad-yellow`, because it was never verified in wave 1.

`slow-*` tags do the same through the latency check (`make release TAG=slow-orange`).

### 3. Breaking a good release live

Promote a fresh good tag (e.g. `yellow`) to `prod-wave1`. While it verifies, open the
Stage's **App** link (needs `make ui`) and turn up the error dial. The extra 500s fail
verification, and Kargo rolls the Stage back to the previous release.

### Things that look like bugs but aren't

- After an automatic rollback, Kargo does not auto-promote that Stage again until a person
  promotes something. A person decides when the fix is ready.
- Kargo does not auto-promote Freight that already failed on a Stage. Ship a new tag.

## Not covered here

These are useful next steps, but this repo doesn't do them:

- QA approval under SSO groups (project RBAC)
- blocking flagged Freight
- Kosli or other audit records written from a promotion step
- non-Kubernetes targets
