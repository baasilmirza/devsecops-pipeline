# DevSecOps on a Local Kubernetes Cluster: Scan in CI, Enforce at Admission

Most "DevSecOps" tutorials stop at adding a scanner to a pipeline. Scanning tells
you what is already wrong; it does nothing about what gets deployed next. This
project does both halves: a CI pipeline that refuses to publish bad artifacts, and
a Kubernetes cluster that refuses to run non-compliant workloads. Same FastAPI app
as the rest of my portfolio, but now it has to earn its place on the cluster.

Everything runs locally on a `kind` cluster. No cloud account, no bill.

## The two halves

```
shift left (the pipeline)
  code ──> gitleaks ──> lint + test ──> Checkov ──> build ──> Trivy ──> syft SBOM ──> push

enforce right (the cluster)
  kubectl apply ──> Kyverno admission ──┬─> admit ──> Pod
                                        └─> deny
  alongside:  RBAC / ServiceAccounts  ·  default-deny NetworkPolicy  ·  Sealed Secrets
```

The two halves are complementary. The pipeline controls the *artifact*. Admission
controls the *cluster state*. A workload can arrive at the cluster from a Helm
chart, a GitOps sync, or a human with `kubectl`, so the cluster has to defend
itself regardless of where the YAML came from.

## Half 1 — the shift-left pipeline

`.github/workflows/security.yml` runs five gates:

- **gitleaks** — fails the build if a credential ever lands in git. A leaked secret
  in history is permanent, so the cheapest place to catch it is before the commit.
- **Checkov** (Kubernetes framework) — the manifests *are* infrastructure. A pod
  without resource limits is a finding, not a style choice. It passed 101 checks
  with zero failures once the workload was hardened.
- **ruff + pytest** — the cheap correctness gates, run first.
- **Trivy** — scans the built image and fails on `HIGH,CRITICAL`, with
  `ignore-unfixed: true` so the gate only blocks on things I can actually fix.
  Unfixed findings still go to code scanning as SARIF instead of being hidden.
- **syft** — emits a CycloneDX SBOM on every build. You cannot respond to a
  zero-day in `libssl` if you don't know which images contain it.

Dependabot opens weekly PRs for pip, GitHub Actions, and the Docker base image, so
the *inputs* to the scan stay current.

The important part is that policy gets the same treatment as application code: the
Kyverno CLI runs in CI, a compliant manifest must pass, and a deliberately bad
manifest must be **denied** — otherwise the build fails. Policy-as-code with
regression tests.

## Half 2 — admission control with Kyverno

Six `ClusterPolicy` objects run in `Enforce` mode:

| Policy | Blocks |
|---|---|
| `require-requests-limits` | Pods with no CPU/memory bounds |
| `disallow-latest-tag` | Untagged images and `:latest` |
| `disallow-privileged` | `securityContext.privileged: true` (cluster-wide) |
| `require-run-as-nonroot` | Containers running as root |
| `require-labels` | Workloads with no owner (`team`, `app.kubernetes.io/name`) |
| `restrict-image-registries` | Images from anywhere but `docker.io` / `ghcr.io` |

A couple of these are worth showing because the pattern language is more subtle
than it looks. Requiring a non-root pod:

```yaml
- name: require-run-as-nonroot
  match:
    any:
      - resources:
          kinds: [Pod]
          namespaces: [portfolio]
  validate:
    message: "Pods in the 'portfolio' namespace must set securityContext.runAsNonRoot: true."
    pattern:
      spec:
        securityContext:
          runAsNonRoot: true
```

Banning `latest` while still requiring *some* tag takes two rules — one to demand a
tag, one to forbid the mutable one:

```yaml
- name: require-image-tag
  validate:
    pattern:
      spec:
        containers:
          - image: "*:*"
- name: disallow-latest
  validate:
    pattern:
      spec:
        containers:
          - image: "!*:latest"
```

The result is exactly what you want from a security control — boring, deterministic
denial:

```
$ kubectl apply -f bad-pod.yaml
Error from server: error when creating "bad-pod.yaml": admission webhook
"validate.kyverno.svc-fail" denied the request:
  resource Pod/portfolio/bad-pod was blocked due to the following policies
  disallow-latest-tag:     Using the mutable 'latest' tag is not allowed.
  require-requests-limits: Pods ... must set CPU and memory requests and limits.
  require-run-as-nonroot:  Pods ... must set securityContext.runAsNonRoot: true.
```

I also layered Pod Security Admission on top: the namespace enforces `baseline` and
audits against `restricted`. Kyverno gives fine-grained, testable policy; PSA is the
platform backstop that keeps working even if the admission controller is down. Two
independent controls, on purpose.

## RBAC: prove the denials, don't assume them

Two ServiceAccounts, both with `automountServiceAccountToken: false` because neither
needs the API server:

- **`portfolio-app`** — read-only on `configmaps` in its own namespace. Nothing else.
- **`deployer`** — can roll deployments forward and read pods, but cannot read
  secrets, cannot delete workloads, and cannot act in another namespace.

The deny side is the part people skip. It is also the part that matters, so
`verify.sh` asserts it:

```
$ kubectl auth can-i get secrets -n portfolio --as=system:serviceaccount:portfolio:deployer
no
$ kubectl auth can-i delete pods -n portfolio --as=system:serviceaccount:portfolio:deployer
no
$ kubectl auth can-i list pods -n default --as=system:serviceaccount:portfolio:deployer
no
```

A deployer that can't read secrets and can't delete anything has a much smaller
blast radius if it is ever compromised.

## Default-deny networking (and why kindnet won't do)

The single most common mistake in local NetworkPolicy demos: `kind`'s default CNI,
kindnet, **does not enforce NetworkPolicy**. You write a perfect default-deny and
nothing happens. So the cluster config disables the default CNI and installs Calico:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
```

Then the namespace starts fully locked:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: portfolio
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
```

No rules means nothing is reachable. Every flow after that is an explicit,
reviewable decision:

- **DNS egress** to `kube-system/kube-dns` on 53 — the one thing everything needs.
- **App ingress** from the namespace on port 8000 only.
- **App egress** to the app pods on 8000 only — no internet, and critically no route
  to the cloud metadata IP `169.254.169.254`.

And it is proven in both directions: an in-namespace call to the app succeeds, a
call from the `default` namespace is dropped.

## Secrets without plaintext

Rule one: no plaintext secret in git, ever.

**Sealed Secrets** is the default. `scripts/seal-secret.sh` encrypts a secret with
the in-cluster controller's public key; only that cluster can decrypt it, so the
sealed output is safe to commit. The example file ships with `CHANGE_ME`
placeholders and nothing else, and gitleaks fails CI if that discipline ever slips.

```bash
$ scripts/seal-secret.sh
sealedsecret.bitnami.com/portfolio-app created
$ kubectl get secret portfolio-app -n portfolio
NAME            TYPE     DATA   AGE
portfolio-app   Opaque   2      0s
```

SOPS + age is documented as the GitOps-friendly alternative, encrypting only the
`data`/`stringData` fields so the manifest stays readable in review.

## The proof

The whole thing is scripted and self-verifying:

```
$ scripts/bootstrap.sh   # kind + Calico + Kyverno + Sealed Secrets
$ scripts/deploy.sh      # build, load, apply RBAC/policies/network/workload, seal secret
$ scripts/verify.sh
...
RESULT: 10 passed, 0 failed
```

`verify.sh` covers all of it: three non-compliant pods denied at admission, the
deployer's allow/deny matrix, an allowed in-namespace call, a denied cross-namespace
call, and the sealed secret decrypting into a real `Secret`.

## Lessons learned

- **kindnet ignores NetworkPolicy.** Disable it and install Calico, or your network
  isolation demo is theatre.
- **The Sealed Secrets Helm repo is gone (404).** Install the controller from the
  official release manifest (`controller.yaml`) instead.
- **`kubectl run` has no `--requests`/`--limits` flags anymore.** Use a small
  manifest instead of fighting the CLI.
- **Checkov will fight a local image.** It wants an image digest and
  `imagePullPolicy: Always`; a locally-built, tag-pinned image can't have either.
  Skip those two checks with a written justification rather than disabling the tool.
- **Admission ordering is not a guarantee you should lean on.** Layer Kyverno and
  Pod Security Admission so neither is a single point of failure.

## What I'd add next

Falco for runtime detection, cosign for image signing plus a Kyverno rule that
verifies signatures before admission, and a service mesh for mTLS. These are listed
as residual risk in the threat model rather than pretended to be done.

## Cost

Zero. It's a local `kind` cluster, destroyed with `scripts/teardown.sh`.

---

*Code: [github.com/baasilmirza/devsecops-pipeline](https://github.com/baasilmirza/devsecops-pipeline)*
