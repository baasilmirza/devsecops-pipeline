# Threat Model — Portfolio API Platform

A lightweight, living threat model for the local DevSecOps platform. It follows
the four questions: what are we building, what can go wrong, what are we doing
about it, and did we do a good job.

## 1. System and scope

```
 developer ──> Git ──> CI (scan + build) ──> registry ──┐
                                                        v
                            kind cluster ──> Kyverno admission ──> Pods
                                 │                   │
                                 │                   ├─ NetworkPolicy
                                 │                   └─ RBAC / ServiceAccounts
                                 └─ Sealed Secrets controller
```

**In scope:** the application image and its supply chain, the CI pipeline, and
the Kubernetes cluster's admission, network, identity, and secret controls.

**Out of scope (and why):** the host OS, the Docker daemon, cloud provider
control planes, and physical security. This project is local and cost-free.

## 2. Assets

| Asset | Why it matters |
|---|---|
| Container image | If tampered with, every deployment runs attacker code |
| Application secrets (API token, DB URL) | Direct path to data and downstream systems |
| Cluster API access | Full control of workloads and secrets if stolen |
| Pod network | Lateral movement between workloads and to the cloud metadata endpoint |
| CI pipeline | Can publish images and read repository secrets |
| Deployment identity (ServiceAccount) | Blast radius of a compromised pod |

## 3. Trust boundaries

1. **Developer / laptop → Git** — code and manifests are untrusted input.
2. **CI → registry** — the built artifact must match the reviewed source.
3. **Registry → cluster** — pulled images are untrusted until scanned.
4. **Pod → Pod** — workloads are mutually untrusted by default.
5. **Pod → Kubernetes API** — every workload is untrusted against the control plane.
6. **Pod → internet / metadata** — egress is a data-exfiltration path.

## 4. Threats and controls (STRIDE-oriented)

| # | Threat | STRIDE | Control | Where |
|---|---|---|---|---|
| T1 | Vulnerable dependency ships to prod | Tampering | Trivy image scan (fail HIGH/CRITICAL), Dependabot | `security.yml` |
| T2 | Typosquatted / unknown base image | Spoofing | Registry allowlist admission policy | `policy/restrict-image-registries.yaml` |
| T3 | Mutable `latest` hides what runs | Tampering | `disallow-latest-tag` policy | `policy/disallow-latest-tag.yaml` |
| T4 | Container escape via privileged mode | Elevation | `disallow-privileged` policy + PSA baseline | `policy/`, `rbac/namespace.yaml` |
| T5 | Root container widens impact | Elevation | `require-run-as-nonroot`, dropped caps, read-only root FS | `policy/`, `workloads/deployment.yaml` |
| T6 | No resource bounds → noisy-neighbour DoS | DoS | `require-requests-limits` policy | `policy/require-requests-limits.yaml` |
| T7 | Secret committed to git | Info disclosure | gitleaks gate + Sealed Secrets + SOPS | `security.yml`, `secrets/` |
| T8 | Secret readable by any pod / CI | Info disclosure | Least-privilege RBAC, no secret verbs, sealed at rest | `rbac/` |
| T9 | Pod token abused against the API | Elevation | `automountServiceAccountToken: false` | `rbac/`, `workloads/` |
| T10 | Lateral movement pod-to-pod | Elevation | Default-deny NetworkPolicy + explicit allowlists | `network/` |
| T11 | Data exfiltration to the internet | Info disclosure | Egress default-deny; only DNS + intra-app allowed | `network/` |
| T12 | Cloud metadata credential theft | Info disclosure | Egress blocked to `169.254.169.254` (no allow rule) | `network/default-deny.yaml` |
| T13 | Unattributed workloads | Repudiation | `require-labels` policy (team + app) | `policy/require-labels.yaml` |
| T14 | Supply chain tampering / no inventory | Tampering | syft SBOM per build + Checkov IaC scan | `security.yml` |

## 5. Residual risk

- **Local only** — no runtime threat detection (Falco), no mTLS/service mesh, no
  image signing (cosign) or admission verification of signatures. Documented as
  the next layer, not claimed as done.
- **Sealed Secrets key custody** — the controller's private key lives in the
  cluster; losing it means re-sealing every secret. Backups are out of scope.
- **CI trust** — a compromised CI runner can exfiltrate secrets it can read;
  mitigated by scoping repository permissions and avoiding long-lived cloud keys.
- **Base image CVEs** — `ignore-unfixed` is set, so unfixed OS CVEs are accepted
  with a tracking issue rather than silently ignored forever.

## 6. Verification

`scripts/verify.sh` exercises the controls and is the evidence that the
mitigations above are actually enforced, not just declared:

- T3/T4/T5/T6 — non-compliant pods are rejected by admission.
- T8 — `kubectl auth can-i` shows the deployer cannot read secrets or delete pods.
- T10/T11 — a cross-namespace call to the app fails; an in-namespace call succeeds.
- T7 — gitleaks runs in CI on every push.

## 7. Review cadence

Re-review on: a new workload or namespace, a new external dependency, a change to
who can deploy, or any incident. The threat model is versioned next to the code
it describes.
