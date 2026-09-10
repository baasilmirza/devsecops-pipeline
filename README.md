# DevSecOps: Shift-Left Pipeline + Runtime Enforcement

A security layer bolted onto the recurring Portfolio API. The same FastAPI app
now has to survive **two** gauntlets: a CI pipeline that scans code, secrets,
manifests, and the built image, and a local Kubernetes cluster that refuses to
run anything non-compliant. The point is not to own scanners — it is to make
"secure" a property that is enforced, tested, and provable.

```
shift left:
  code ──> gitleaks ──> lint+test ──> Checkov ──> build ──> Trivy ──> syft SBOM ──> push

enforce right:
  apply ──> Kyverno admission ──┬─> admit (compliant)  ──> Pod
                                └─> deny  (no limits, latest tag, privileged, ...)

  alongside:  RBAC / ServiceAccounts  ·  default-deny NetworkPolicy  ·  Sealed Secrets
```

## What this proves

1. **Shift-left scanning** — gitleaks, Checkov, Trivy, and syft run as CI gates,
   with an SBOM emitted per build.
2. **Policy-as-code admission** — six Kyverno `Enforce` policies block
   non-compliant pods at the API server, and are regression-tested with the
   Kyverno CLI.
3. **Least-privilege RBAC** — scoped ServiceAccounts and Roles, with the denials
   asserted, not assumed.
4. **Default-deny networking** — Calico-backed `NetworkPolicy` with explicit
   allowlists for DNS and intra-app traffic only.
5. **Secrets without plaintext** — Sealed Secrets (default) and SOPS + age
   (documented), with gitleaks as the tripwire.
6. **A documented threat model** — assets, trust boundaries, STRIDE threats, and
   the control that answers each one.

## Architecture

```
                    ┌──────────────────────────────────────────────┐
                    │                 CI (GitHub)                  │
                    │  gitleaks → ruff+pytest → Checkov →          │
                    │  build → Trivy → syft SBOM → push            │
                    └──────────────────────┬───────────────────────┘
                                           │ image
                    ┌──────────────────────v───────────────────────┐
                    │            kind cluster "devsecops"          │
                    │  Calico (NetworkPolicy enforcement)          │
                    │                                              │
                    │  Kyverno  ── admission webhook               │
                    │     │                                        │
                    │  namespace: portfolio                        │
                    │     ├─ Deployment portfolio-app (non-root,   │
                    │     │   limits, read-only FS, no SA token)   │
                    │     ├─ RBAC: portfolio-app, deployer         │
                    │     ├─ NetworkPolicy: default-deny + allow   │
                    │     └─ Sealed Secret → Secret portfolio-app  │
                    └──────────────────────────────────────────────┘
```

Key choices:

- **Calico, not kindnet** — kind's default CNI silently ignores `NetworkPolicy`;
  the cluster config disables it so the network demos are real.
- **Admission + PSA, layered** — Kyverno gives fine-grained, testable policy;
  Pod Security Admission (`baseline` enforce, `restricted` audit) is the
  platform backstop that survives an add-on outage.
- **Two service accounts, both token-less** — the app needs nothing from the API
  server, so it gets no token and read-only `configmaps`; the deployer can move
  the app forward but cannot read secrets or delete anything.
- **Sealed Secrets default, SOPS documented** — one working mechanism plus a
  GitOps-friendly alternative, instead of committing a plaintext secret.

## Repository layout

```
app/                    # FastAPI app (reused from P1)
tests/                  # unit tests
Dockerfile              # hardened multi-stage image (non-root, no pip in runtime)
.github/
├── workflows/security.yml   # gitleaks, Checkov, lint/test, Kyverno CLI, build+Trivy+SBOM
└── dependabot.yml           # pip, actions, docker
policy/                 # Kyverno ClusterPolicies (6)
rbac/                   # namespace, 2 ServiceAccounts, Roles, RoleBindings
network/                # default-deny + DNS/app allowlists
secrets/                # .sops.yaml, sealed-secret flow, example (placeholders only)
workloads/              # policy-compliant Deployment + Service
kind/cluster.yaml       # kind config: Calico, no default CNI
scripts/
├── bootstrap.sh        # kind + Calico + Kyverno + Sealed Secrets
├── deploy.sh           # build, load, apply RBAC/network/workloads/policies, seal secret
├── seal-secret.sh      # kubeseal the example secret and apply it
├── verify.sh           # prove every acceptance criterion
└── teardown.sh         # delete the cluster
docs/
├── threat-model.md     # assets, trust boundaries, STRIDE, residual risk
└── blog-07-devsecops.md
```

## Prerequisites

- Docker
- `kind`, `kubectl`, `helm`, `kubeseal`
- `gitleaks` (optional locally; runs in CI)

## Quickstart

```bash
# 1. Create the cluster + Calico + Kyverno + Sealed Secrets
scripts/bootstrap.sh

# 2. Build the image, apply RBAC/network/workloads/policies, seal the secret
scripts/deploy.sh

# 3. Prove it
scripts/verify.sh
```

## Verifying each acceptance criterion

| Criterion | How it is proven |
|---|---|
| CI scans: Trivy, syft SBOM, Checkov, gitleaks | `.github/workflows/security.yml` jobs; SBOM uploaded as an artifact |
| Kyverno blocks non-compliant workloads | `scripts/verify.sh` [1–3]: no-limits, `:latest`, and privileged pods are denied |
| RBAC + ServiceAccounts, least privilege | `scripts/verify.sh` [5–8]: deployer can list deployments, cannot read secrets, cannot delete pods, cannot leave the namespace |
| NetworkPolicy default-deny with allowlists | `scripts/verify.sh` [9–10]: in-namespace call succeeds, cross-namespace call is dropped |
| Secrets sealed, no plaintext in git | `scripts/verify.sh` [11–12]; `secrets/` ships only `CHANGE_ME` placeholders |
| Threat model documented | [`docs/threat-model.md`](docs/threat-model.md) |
| README complete | this file |

## Security posture

- **Image**: multi-stage, non-root `appuser`, no `pip`/`wheel` in the runtime layer,
  `readOnlyRootFilesystem`, all capabilities dropped, `seccompProfile: RuntimeDefault`.
- **Admission**: non-root, resource bounds, explicit tags, registry allowlist,
  no privileged containers, ownership labels.
- **Identity**: no auto-mounted tokens; `deployer` cannot read secrets.
- **Network**: ingress and egress default-deny; only DNS and intra-app traffic allowed.
- **Secrets**: sealed at rest; gitleaks fails the build on any plaintext secret.

## Known quirks

- **kindnet ignores NetworkPolicy** — the cluster must be created with
  `disableDefaultCNI: true` and Calico installed, or the network tests are theatre.
- **Kyverno `restrict-image-registries` and local images** — the app image is
  tagged `docker.io/library/portfolio-api:0.1.0` so it satisfies the registry
  allowlist; a bare `portfolio-api:0.1.0` would be read as an unqualified
  `docker.io` name but the explicit tag removes all ambiguity.
- **`readOnlyRootFilesystem`** — the deployment mounts an `emptyDir` at `/tmp`
  because the Python runtime may want scratch space.
- **Sealed secrets are cluster-bound** — `secrets/sealed-secret.yaml` is
  gitignored; regenerate it against a new cluster with `scripts/seal-secret.sh`.

## Destroy

```bash
scripts/teardown.sh      # kind delete cluster
```

## Cost

Zero. Everything runs locally in a kind cluster. No cloud resources, no
plaintext secrets committed.

## Blog post

See [`docs/blog-07-devsecops.md`](docs/blog-07-devsecops.md) — shift-left
pipeline → Kyverno policy examples → default-deny networking → secrets story.
