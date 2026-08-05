#!/usr/bin/env bash
# GitOps-path verification: applies gitops/project.yaml and
# gitops/application.yaml, then asserts (does not just print) that the
# ArgoCD Application reaches Synced/Healthy — proof that the sync-wave/
# PostSync-hook ordering (see docs/decisions.md "Migration ordering") and
# the readiness-gated app actually converge when driven by ArgoCD, not
# just by plain `helm install`.
#
# Deliberately separate from scripts/verify.sh / `make verify`: this
# requires ArgoCD to be installed (`make argocd`) and — since this repo is
# currently private — a repository credential registered with ArgoCD
# first (`argocd repo add <repoURL> --username ... --password ...`, or an
# SSH deploy key). Once the repo is public, no credential is needed and
# this becomes a plain `make verify-gitops` away from proving the GitOps
# path end to end.
#
# Exits non-zero on the first failed assertion.

set -euo pipefail

NAMESPACE="argocd"
APP_NAME="reference-stack"

log() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

log "applying gitops/project.yaml and gitops/application.yaml"
kubectl apply -f gitops/project.yaml
kubectl apply -f gitops/application.yaml

log "waiting for Application '${APP_NAME}' to reach Synced (up to 180s)"
if ! kubectl wait --for=jsonpath='{.status.sync.status}'=Synced \
  "application/${APP_NAME}" -n "${NAMESPACE}" --timeout=180s 2>/tmp/verify-gitops-sync.log; then
  cat /tmp/verify-gitops-sync.log >&2
  SYNC_STATUS=$(kubectl get application "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "unknown")
  fail "Application '${APP_NAME}' did not reach Synced (currently: ${SYNC_STATUS}) — if this is a private repo, register credentials first: 'argocd repo add <repoURL> --username ... --password ...'"
fi
log "Application Synced"

log "waiting for Application '${APP_NAME}' to reach Healthy (up to 180s)"
if ! kubectl wait --for=jsonpath='{.status.health.status}'=Healthy \
  "application/${APP_NAME}" -n "${NAMESPACE}" --timeout=180s 2>/tmp/verify-gitops-health.log; then
  cat /tmp/verify-gitops-health.log >&2
  fail "Application '${APP_NAME}' did not reach Healthy"
fi
log "Application Healthy"

log "all GitOps verification checks passed"
