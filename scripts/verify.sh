#!/usr/bin/env bash
# Runtime verification for the deployed reference-stack release.
#
# `make install` deliberately runs `helm upgrade --install` WITHOUT --wait
# (see the Makefile and docs/decisions.md "Migration ordering (round 2)"):
# --wait would block on the app Deployment's readiness before Helm even
# runs the post-install migration Job that readiness depends on. This
# script is what actually waits for the release to converge, explicitly
# and in the right order, before asserting anything about it.
#
# Asserts (does not just print) that:
#   1. the migration Job completes successfully (kubectl wait)
#   2. the app Deployment becomes Ready (kubectl rollout status — this can
#      only succeed once /readyz is happy, which depends on step 1)
#   3. the app's /healthz returns 200 through a port-forward
#   4. a write to /items persists across an app pod restart
#   5. Redis is actually being hit (the cache key exists after a read)
#
# Exits non-zero on the first failed assertion.

set -euo pipefail

RELEASE="${1:?usage: verify.sh <release> <namespace>}"
NAMESPACE="${2:?usage: verify.sh <release> <namespace>}"

APP_LABEL="app.kubernetes.io/instance=${RELEASE}"
APP_SVC="${RELEASE}-app"
APP_PORT="8000"
LOCAL_PORT="18000"
PF_PID=""

log() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# 1. Migration Job completes successfully.
#
# The Job's hook-delete-policy includes hook-succeeded (see
# templates/migration/job.yaml), so it can legitimately already be gone by
# the time this script runs — `make verify` isn't guaranteed to run in the
# few seconds between `make install` returning and a fast migration
# finishing and self-deleting. So: if the Job still exists, wait for it to
# reach condition=complete. If it's already gone, that's only a pass if
# the schema is actually there — checked via the app's /readyz once the
# port-forward is up below. A Job that's gone AND an unmigrated schema is
# the real failure case, which readyz will catch.
JOB_NAME=$(kubectl get jobs -n "${NAMESPACE}" -l "${APP_LABEL},app.kubernetes.io/component=migration" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${JOB_NAME}" ]]; then
  log "waiting for migration Job '${JOB_NAME}' to complete (up to 300s)"
  if ! kubectl wait --for=condition=complete "job/${JOB_NAME}" -n "${NAMESPACE}" --timeout=300s 2>/tmp/verify-job-wait.log; then
    cat /tmp/verify-job-wait.log >&2
    fail "migration Job '${JOB_NAME}' did not reach condition=complete — check 'kubectl logs job/${JOB_NAME} -n ${NAMESPACE}'"
  fi
  log "migration Job '${JOB_NAME}' completed successfully"
else
  log "migration Job already cleaned up (hook-succeeded) — will confirm via /readyz below"
fi

# 2. App Deployment becomes Ready. This can only succeed once /readyz is
# happy, which itself depends on the migration Job above having created
# the schema — so this assertion also transitively proves ordering held.
log "waiting for app Deployment to become Ready (up to 180s)"
if ! kubectl rollout status deployment "${APP_SVC}" -n "${NAMESPACE}" --timeout=180s; then
  fail "app Deployment '${APP_SVC}' did not become Ready"
fi
log "app Deployment Ready"

# Set up a single port-forward reused by checks 3-5.
log "starting port-forward to svc/${APP_SVC}"
kubectl port-forward -n "${NAMESPACE}" "svc/${APP_SVC}" "${LOCAL_PORT}:${APP_PORT}" >/tmp/verify-portforward.log 2>&1 &
PF_PID=$!
for _ in $(seq 1 20); do
  if curl -sf "http://localhost:${LOCAL_PORT}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# 3. /healthz returns 200, and /readyz confirms the schema is migrated —
# the latter is the actual proof point when the migration Job check above
# had to fall back on "already cleaned up" (see the comment there).
log "checking /healthz"
HEALTZ_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${LOCAL_PORT}/healthz")
if [[ "${HEALTZ_CODE}" != "200" ]]; then
  fail "/healthz returned ${HEALTZ_CODE}, expected 200"
fi
log "checking /readyz"
READYZ_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${LOCAL_PORT}/readyz")
if [[ "${READYZ_CODE}" != "200" ]]; then
  fail "/readyz returned ${READYZ_CODE}, expected 200 — schema not migrated or a dependency unreachable"
fi
log "/healthz and /readyz both returned 200"

# 4. Write persists across an app pod restart.
log "writing a marker item"
MARKER="verify-$(date +%s)"
CREATE_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:${LOCAL_PORT}/items" \
  -H 'Content-Type: application/json' -d "{\"name\": \"${MARKER}\"}")
if [[ "${CREATE_CODE}" != "201" ]]; then
  fail "POST /items returned ${CREATE_CODE}, expected 201"
fi

log "restarting app pods"
kubectl rollout restart deployment "${APP_SVC}" -n "${NAMESPACE}"
kubectl rollout status deployment "${APP_SVC}" -n "${NAMESPACE}" --timeout=120s

# Port-forward dies with the old pod; restart it against the new one.
kill "${PF_PID}" 2>/dev/null || true
wait "${PF_PID}" 2>/dev/null || true
kubectl port-forward -n "${NAMESPACE}" "svc/${APP_SVC}" "${LOCAL_PORT}:${APP_PORT}" >/tmp/verify-portforward.log 2>&1 &
PF_PID=$!
for _ in $(seq 1 20); do
  if curl -sf "http://localhost:${LOCAL_PORT}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

log "checking marker item survived the restart"
if ! curl -s "http://localhost:${LOCAL_PORT}/items" | grep -q "${MARKER}"; then
  fail "item '${MARKER}' not found in /items after pod restart — write did not persist to Postgres"
fi
log "write persisted across pod restart"

# 5. Redis is actually being hit: the cache key must exist after a read.
log "checking Redis cache key exists after a read"
curl -s "http://localhost:${LOCAL_PORT}/items" >/dev/null
REDIS_POD=$(kubectl get pods -n "${NAMESPACE}" -l "${APP_LABEL},app.kubernetes.io/component=redis" \
  -o jsonpath='{.items[0].metadata.name}')
CACHE_EXISTS=$(kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli EXISTS items:all)
if [[ "${CACHE_EXISTS}" != "1" ]]; then
  fail "Redis key 'items:all' does not exist after a read — cache is not being populated"
fi
log "Redis cache key 'items:all' exists"

log "all verification checks passed"
