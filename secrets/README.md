# Secrets

Two mechanisms, one rule: **no plaintext secret ever lands in git.**

## Option A — Sealed Secrets (default for this project)

A one-way encryption using the controller's public key. Only the controller
inside the cluster can decrypt, so the sealed output is safe to commit.

```bash
# controller is installed by scripts/bootstrap.sh
scripts/seal-secret.sh          # seals secrets/app-secret.example.yaml
kubectl get secret portfolio-app -n portfolio
```

`scripts/seal-secret.sh` writes `secrets/sealed-secret.yaml`, which is
gitignored because the ciphertext is bound to the cluster's keypair.

## Option B — SOPS + age (for GitOps)

`secrets/.sops.yaml` encrypts only the `data`/`stringData` fields, keeping the
manifest readable in review.

```bash
age-keygen -o age.key           # keep age.key out of git
# put the public key into secrets/.sops.yaml
sops --encrypt secrets/app-secret.example.yaml > secrets/app-secret.sops.yaml
```

## Why

- A leaked plaintext secret in git history is permanent; a leaked *sealed*
  secret is useless without the cluster's private key.
- `gitleaks` runs in CI (`.github/workflows/security.yml`) and fails the build
  if a credential-shaped string is ever committed.
- The example file contains only `CHANGE_ME` placeholders on purpose.
