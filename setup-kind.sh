
#!/usr/bin/env bash
# setup-env.sh — rebuild kind + ArgoCD learning environment from scratch\

CLUSTER_NAME = "uat"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo ">>> kind cluster '${CLUSTER_NAME}' already exists, skipping."
else
  echo ">>> Creating kind cluster '${CLUSTER_NAME}' (1 CP + 2 workers)..."
  cat <<EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"
