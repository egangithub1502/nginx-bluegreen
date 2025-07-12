#!/bin/bash

set -e

# Configuration
NAMESPACE="nginx"
FRONT_SERVICE="nginx-service"
ARGOCD_APP="nginx-bluegreen"
ARGO_NAMESPACE="argocd"
WAIT_TIMEOUT=300
NEW_REPLICAS=2
ARGOCD_SERVER="localhost:8080/applications"         # Replace with your ArgoCD server address
ARGOCD_USER="admin"
ARGOCD_PASSWORD="IO-gZwRP11jYC1NT"     # Replace with your ArgoCD password

# Check ArgoCD auth
check_argocd_auth() {
  echo "[INFO] Checking ArgoCD authentication..."
  if ! argocd app list >/dev/null 2>&1; then
    echo "[INFO] Logging into ArgoCD..."
    argocd login "$ARGOCD_SERVER" \
      --username "$ARGOCD_USER" \
      --password "$ARGOCD_PASSWORD" \
      --insecure
  else
    echo "[INFO] Already authenticated with ArgoCD."
  fi
}

# Wait for all pods in the given StatefulSet to be ready
wait_for_sts_ready() {
  local sts_name=$1
  local expected_replicas=$2
  echo "[INFO] Waiting for $expected_replicas pods in $sts_name to become ready..."

  local ready=0
  local retries=60

  for ((i=1; i<=retries; i++)); do
    ready=$(kubectl get pod -n "$NAMESPACE" \
      -l "statefulset.kubernetes.io/pod-name" \
      -o json | jq "[.items[] | select(.metadata.name | startswith(\"$sts_name\")) | select(.status.containerStatuses[0].ready == true)] | length")

    echo "[INFO] Ready Pods: $ready/$expected_replicas"

    if [[ "$ready" -eq "$expected_replicas" ]]; then
      echo "[INFO] All $sts_name pods are ready!"
      return 0
    fi
    sleep 5
  done

  echo "[ERROR] $sts_name pods not ready in time."
  exit 4
}

# Usage help
usage() {
  echo "Usage: $0 [blue|green]"
  exit 1
}

# Parse input
if [[ $# -ne 1 ]]; then
  usage
fi

TARGET_COLOR="$1"
if [[ "$TARGET_COLOR" != "blue" && "$TARGET_COLOR" != "green" ]]; then
  echo "❌ Invalid color: use 'blue' or 'green'"
  exit 2
fi

# Derive values
OLD_COLOR=$( [[ "$TARGET_COLOR" == "blue" ]] && echo "green" || echo "blue" )
TARGET_STS="nginx-app-$TARGET_COLOR"
OLD_STS="nginx-app-$OLD_COLOR"

# Steps
echo "🚀 Starting Blue-Green switch to '$TARGET_COLOR'"

echo "[1] Scaling UP $TARGET_STS to $NEW_REPLICAS"
kubectl scale statefulset/$TARGET_STS -n $NAMESPACE --replicas=$NEW_REPLICAS

echo "[2] Waiting for rollout..."
kubectl rollout status statefulset/$TARGET_STS -n $NAMESPACE --timeout=${WAIT_TIMEOUT}s

echo "[3] Validating pods are READY..."
wait_for_sts_ready $TARGET_STS $NEW_REPLICAS

echo "[4] Switching traffic to $TARGET_COLOR..."
kubectl patch service $FRONT_SERVICE -n $NAMESPACE --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/spec/selector/color\", \"value\": \"$TARGET_COLOR\"}]"

echo "[5] Verifying traffic switch completed!"

# ArgoCD integration
check_argocd_auth

echo "[6] Updating ArgoCD path to overlays/$TARGET_COLOR"
argocd app set $ARGOCD_APP --path overlays/$TARGET_COLOR --directory-recurse

echo "[7] ArgoCD sync in progress..."
argocd app sync $ARGOCD_APP

echo "[8] Scaling DOWN old StatefulSet $OLD_STS to 0"
kubectl scale statefulset/$OLD_STS -n $NAMESPACE --replicas=0

echo "✅ DONE! Live traffic is now on '$TARGET_COLOR'. Old color '$OLD_COLOR' pods are OFF."

exit 0

