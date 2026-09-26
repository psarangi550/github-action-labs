# GitHub Actions Labs

This repository contains GitHub Actions examples and the source-controlled configuration for a repository-scoped self-hosted runner on Kubernetes. The runner is managed by Actions Runner Controller (ARC).

No command in this repository deploys resources automatically. Review and run the commands below from your own terminal when you are ready.

## Using your own fork

All owner/repo/image references live in one place: `deploy/arc-runner/values.yaml`. To point this setup at your own fork, edit that file before doing anything else:

```yaml
runner:
  repository: <your-github-username>/<your-repo>       # e.g. octocat/github-action-labs
  image:
    repository: ghcr.io/<your-github-username>/github-action-labs-runner
```

Everything else in this README and in `scripts/setup-runner.sh` derives `GHCR_USERNAME` and the target repository from that file, so you should not need to edit the script or the workflows.

## Repository layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/` | GitHub Actions workflows that run on the self-hosted runner. |
| `docker/runner/Dockerfile` | Custom GitHub Actions runner image. |
| `deploy/arc-controller/values.yaml` | Helm values for the ARC controller. |
| `deploy/arc-runner/` | Helm chart that creates the repository runner. |
| `scripts/setup-runner.sh` | Recreates cert-manager, ARC, GHCR credentials, and the repository runner. |
| `.env` | Local-only GitHub PAT source. This file is ignored by Git. |

## Prerequisites

1. A Kubernetes cluster and a `kubectl` context pointing at it.
2. Helm 3.
3. Docker with permission to push to GitHub Container Registry (GHCR).
4. A GitHub personal access token for the repository set in `deploy/arc-runner/values.yaml` (`runner.repository`). You must have write/admin access to that repository:
   - Classic PAT: `repo` scope.
   - Fine-grained PAT: **Administration: Read and write** on that repository (required to mint runner registration tokens), plus `write:packages`/`read:packages` if you use it to push/pull the runner image on GHCR.
5. Permission to create Kubernetes namespaces, secrets, and Helm releases.

> A 403 error such as `You must have repository write permissions or have the repository runners fine-grained permission` when the runner registers means the token above doesn't have sufficient access to the target repository — it is not a bug in this chart. If you don't own the repository, ask an admin to grant access or generate the token themselves.

Check the local tools and cluster context before continuing:

```bash
kubectl config current-context
kubectl get nodes
helm version --short
docker version --format '{{.Server.Version}}'
```

## 1. Store the GitHub token locally

Keep the PAT out of Git and Kubernetes manifests. Create or update `.env` locally:

```bash
printf 'GITHUB_PAT=%s\n' 'replace-with-your-token' > .env
chmod 600 .env
```

Load it only in the terminal session that needs it:

```bash
set -a
. ./.env
set +a
test -n "$GITHUB_PAT"
```

The `.env` file is ignored by Git. Do not add the PAT to Helm values, workflow files, Dockerfiles, or commits.

## Recreate the runner

After the runner image for the tag in `deploy/arc-runner/values.yaml` is available in GHCR, run the setup script from the repository root:

```bash
./scripts/setup-runner.sh
```

The script sources `.env` when `GITHUB_PAT` is not already set, uses Helm to create the required namespaces and releases, and creates or updates the runtime-only `ghcr-pull` secret. It changes the current Kubernetes cluster.

## 2. Build and publish the runner image

The runner image extends `summerwind/actions-runner` with `ca-certificates`, `curl`, and `git`.

Authenticate Docker to GHCR, then build and publish the image:

```bash
IMAGE_TAG=v1.0.0
GHCR_USERNAME=<your-github-username>   # must match deploy/arc-runner/values.yaml

printf '%s' "$GITHUB_PAT" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin

docker build \
	--tag ghcr.io/"$GHCR_USERNAME"/github-action-labs-runner:"$IMAGE_TAG" \
	docker/runner

docker push ghcr.io/"$GHCR_USERNAME"/github-action-labs-runner:"$IMAGE_TAG"
```

The chart image tag is configured in `deploy/arc-runner/values.yaml`. Use a new immutable tag for every image change. New GHCR packages default to **private** — the `ghcr-pull` secret (step 6) must authenticate as a user with read access to the package, or pods will sit in `ImagePullBackOff`.

### Publish with GitHub Actions

`.github/workflows/publish-runner-image.yaml` publishes the same image to GHCR using the repository `GITHUB_TOKEN`; no personal access token is stored in GitHub Actions secrets. It deliberately uses GitHub-hosted `ubuntu-latest` so the first runner image can be published before the self-hosted runner exists.

To publish a release image, create and push a new version tag. The tag becomes the image tag:

```bash
git tag v1.0.1
git push origin v1.0.1
```

Alternatively, run **Publish runner image** from the GitHub Actions tab and enter an unused version such as `v1.0.1`. After the image is published, the workflow updates `runner.image.tag` on `main` and commits the deployment configuration automatically.

## 3. Add the ARC Helm repository

```bash
helm repo add actions-runner-controller \
	https://actions-runner-controller.github.io/actions-runner-controller
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

Validate the repository runner chart before installation:

```bash
helm lint deploy/arc-runner
helm template github-action-labs-runner deploy/arc-runner
```

## 4. Install cert-manager

ARC requires cert-manager to provide the `Certificate` and `Issuer` resources used for its serving certificate. Helm creates the `cert-manager` namespace and installs the CRDs from the tracked values file.

```bash
helm upgrade --install cert-manager jetstack/cert-manager \
	--namespace cert-manager \
	--create-namespace \
	--values deploy/cert-manager/values.yaml \
	--wait
```

Verify cert-manager is ready before installing ARC:

```bash
kubectl get pods --namespace cert-manager
kubectl get crd certificates.cert-manager.io issuers.cert-manager.io
```

## 5. Install Actions Runner Controller

Helm creates the `arc-systems` namespace and the `controller-manager` secret. The PAT is passed from the current shell using `--set-file`; it is not written to a values file.

```bash
helm upgrade --install arc \
	actions-runner-controller/actions-runner-controller \
	--namespace arc-systems \
	--create-namespace \
	--values deploy/arc-controller/values.yaml \
	--set-file authSecret.github_token=<(printf '%s' "$GITHUB_PAT") \
	--wait
```

If a previous setup created `controller-manager` with `kubectl`, delete that old secret before running this command. Helm will recreate it with the current PAT and its required ownership metadata:

```bash
kubectl delete secret controller-manager --namespace arc-systems
```

Verify the secret exists without displaying its value:

```bash
kubectl get secret controller-manager --namespace arc-systems
```

Check that the controller is ready:

```bash
kubectl get pods --namespace arc-systems
helm list --namespace arc-systems
```

### Chart download timeout fallback

If Helm times out downloading the ARC chart from GitHub Releases, download the version from the repository index with retries and install the local archive instead:

```bash
mkdir -p .helm-cache
curl --fail --location --retry 5 --retry-all-errors \
	--connect-timeout 30 --max-time 600 \
	--output .helm-cache/actions-runner-controller-0.23.7.tgz \
	https://github.com/actions/actions-runner-controller/releases/download/actions-runner-controller-0.23.7/actions-runner-controller-0.23.7.tgz
```

Replace `actions-runner-controller/actions-runner-controller` in the installation command with `.helm-cache/actions-runner-controller-0.23.7.tgz`.

## 6. Install the repository runner

The custom runner image is private in GHCR. Create the `ghcr-pull` secret from a token with package read access before installing the chart:

```bash
kubectl create secret docker-registry ghcr-pull \
	--namespace arc-runners \
	--docker-server=ghcr.io \
	--docker-username=<your-github-username> \
	--docker-password="$GITHUB_PAT" \
	--dry-run=client -o yaml | kubectl apply -f -
```

The username must match the GHCR namespace in `runner.image.repository`; a mismatched username causes `403 Forbidden`/`denied` pull errors even if the token is otherwise valid.

The secret is referenced by `runner.imagePullSecrets` in `deploy/arc-runner/values.yaml` and is not stored in Git.

```bash
helm upgrade --install github-action-labs-runner \
	deploy/arc-runner \
	--namespace arc-runners \
	--create-namespace \
	--wait
```

The chart creates a `RunnerDeployment` named `github-action-labs` for the repository set in `runner.repository`.

Verify the runner resources and registration:

```bash
kubectl get runnerdeployments --namespace arc-runners
kubectl get runners --namespace arc-runners
kubectl get pods --namespace arc-runners
```

GitHub also lists the runner under **Settings** > **Actions** > **Runners** for this repository.

## 7. Run the workflows

The workflows in `.github/workflows/` use this label:

```yaml
runs-on: github-action-labs
```

Push a change to `main` or run either workflow manually from the GitHub Actions tab. While a job is executing, inspect the runner pod:

```bash
kubectl get pods --namespace arc-runners --watch
kubectl logs --namespace arc-systems deployment/arc-actions-runner-controller
```

## 8. Troubleshooting

If the ARC controller crash-loops with an empty or invalid private-key error, confirm `GITHUB_PAT` is set in the current terminal, update the Helm release with the required `authSecret.github_token` value, then restart the controller:

```bash
test -n "$GITHUB_PAT"
token_file=$(mktemp)
trap 'rm -f "$token_file"' EXIT
printf '%s' "$GITHUB_PAT" > "$token_file"

helm upgrade arc actions-runner-controller/actions-runner-controller \
	--namespace arc-systems \
	--values deploy/arc-controller/values.yaml \
	--set-file authSecret.github_token="$token_file"

kubectl rollout restart deployment/arc-actions-runner-controller \
	--namespace arc-systems
kubectl rollout status deployment/arc-actions-runner-controller \
	--namespace arc-systems --timeout=2m
```

If the runner pod is in `ImagePullBackOff`, confirm that the image was pushed and that the `ghcr-pull` secret exists in `arc-runners` and uses the correct username:

```bash
docker push ghcr.io/<your-github-username>/github-action-labs-runner:<image-tag>
kubectl get secret ghcr-pull --namespace arc-runners
kubectl get pods --namespace arc-runners
```

If the runner never registers with GitHub and the controller logs show `Failed to get new registration token` with a `403`, the PAT does not have write/admin access to `runner.repository` (see Prerequisites). Rotate/regenerate the token, update the `controller-manager` secret, and restart the controller:

```bash
kubectl create secret generic controller-manager --namespace arc-systems \
	--from-literal=github_token="$GITHUB_PAT" \
	--dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/arc-actions-runner-controller --namespace arc-systems
```

If `kubectl get runnerdeployments` shows `DESIRED 0` even though `runner.replicas` is `1` in `values.yaml`, a previous `helm upgrade`/`--set` may have pinned `replicas: 0` on the release, and Helm's three-way merge won't correct a field that hasn't changed chart-side. Confirm and force it back:

```bash
helm get values github-action-labs-runner --namespace arc-runners
kubectl patch runnerdeployment github-action-labs --namespace arc-runners \
	--type=merge -p '{"spec":{"replicas":1}}'
```

Every file under `deploy/*/templates/` is rendered by Helm as a manifest (only `_`-prefixed files are treated as non-rendered partials). Never keep two template files that define the same resource (e.g. a `.yaml` and a leftover `.tpl` copy) — Helm applies both on every upgrade, and the ARC controller will thrash, repeatedly deleting and recreating `RunnerReplicaSet`s. If you see many `RunnerReplicaSetDeleted` events in a short window, check `ls deploy/arc-runner/templates/` for duplicates and `kubectl get runnerreplicasets --namespace arc-runners` for more than one replica set — delete the stale one (the one referencing the old image/repository).

## 9. Maintain the runner

Update `deploy/arc-runner/values.yaml` to change the repository, image, runner label, or steady-state runner count. The publishing workflow updates `runner.image.tag` automatically on `main`; pull that commit before applying the new image to the cluster:

```bash
git pull --ff-only
helm lint deploy/arc-runner
helm upgrade github-action-labs-runner deploy/arc-runner \
	--namespace arc-runners \
	--wait
```

Before updating the controller chart, review available versions:

```bash
helm search repo actions-runner-controller/actions-runner-controller --versions
```

## 10. Remove runner resources

To remove the repository runner but retain the cluster and ARC controller:

```bash
helm uninstall github-action-labs-runner --namespace arc-runners
```

To remove ARC as well, first remove the repository runner, then run:

```bash
helm uninstall arc --namespace arc-systems
kubectl delete namespace arc-runners arc-systems
```

Deleting the namespaces removes the controller secret. It does not delete Kubernetes nodes or the cluster itself.
