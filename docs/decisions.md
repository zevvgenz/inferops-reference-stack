# Design decisions

Detailed reasoning behind decisions that didn't fit a one-sentence bullet in
the README. Each entry records the problem, the options considered, and why
the chosen option won — written for whoever (human or AI agent) touches
this ordering logic next, without needing this session's chat history.

## Migration ordering (round 1)

**Problem.** The migration Job must run after Postgres is reachable and
before the app serves traffic. The first implementation put the Job on a
`pre-install,pre-upgrade` Helm hook, reasoning that Helm blocks the release
until pre-install hooks succeed. That failed on the very first live install
against a local kind cluster: `pre-install` hooks run *before Helm applies
any of the chart's ordinary resources*. Postgres's StatefulSet, its
Service, the app's Secret and ConfigMap did not exist yet, so the Job's
`wait-for-postgres` initContainer polled a hostname that had no backing
Service and hung until `activeDeadlineSeconds` killed it. This is a classic
chicken-and-egg failure in Helm hook design: a pre-install hook cannot
depend on anything installed by the same release.

**Options considered.**

1. **Make Postgres/Redis/Secret/ConfigMap pre-install hooks too**, at a
   lower `hook-weight` than the Job, so they'd exist before it runs.
   Rejected: it turns the Postgres StatefulSet — a stateful resource with a
   PVC — into a hook resource. Helm hook resources are not tracked as part
   of the release the way ordinary resources are, and their lifecycle
   (particularly around `hook-delete-policy` and re-runs) is designed for
   disposable objects like migration Jobs, not for anything holding a
   PersistentVolumeClaim. Getting that policy wrong risks the PVC being
   deleted and recreated on an upgrade — silent data loss in the one piece
   of this stack that must never lose data. Not worth the risk for an
   ordering problem that has a clean alternative.

2. **Drop `pre-install`, keep only `pre-upgrade`**, and document that a
   fresh install needs `helm install && helm upgrade` (or a documented
   "run install twice") before the stack is actually usable. Rejected: it
   directly breaks the README's `make cluster && make install && make
   verify` quickstart promise — the single most important thing a
   reviewer will run. A workaround that contradicts the repo's own
   definition of done is not an acceptable fix.

3. **`post-install,post-upgrade` hook (Helm), combined with a
   readiness-based gate on the app.** Chosen for the plain-Helm path. The
   migration Job becomes a post-install/post-upgrade hook: Postgres,
   Redis, the Secret, and the ConfigMap are ordinary chart resources that
   get applied in the same phase as the Job starts, so `wait-for-postgres`
   now waits on something that is actually coming up, not something that
   doesn't exist yet. The app Deployment is *not* ordered relative to the
   Job by hook weight at all — it starts immediately, alongside the
   migration Job. What keeps it from serving traffic before the schema
   exists is its own `/readyz` readiness probe (see "Liveness vs
   readiness" below), which returns 503 until the `items` table is
   present. `helm install --wait` blocks on every resource's readiness,
   including the Deployment's, so the release only reports success once
   the schema is migrated and the app is actually ready to serve `/items`.

**Why this is the right shape, not just a workaround.** Ordering resources
by imperative hook sequencing (pre-install weight -3, -2, -1, 0, 1, 2...)
is a common Helm anti-pattern: it re-encodes a startup script's ordering
assumptions into annotations, and it's exactly the kind of thing that
silently breaks the next time someone adds a resource and forgets to
renumber the weights. Kubernetes' actual ordering primitive is
reconciliation against a readiness condition, not a script. Gating the app
behind its own readiness probe is the idiomatic way to express "don't
serve traffic until you're ready" — it's self-verifying (the probe result
*is* the check, not a proxy for it), it degrades gracefully if the
migration is slow, and it requires no coordination between the Job's hook
configuration and the Deployment's.

**This does not carry over to ArgoCD unchanged** — an initial assumption
here was that a `PostSync` migration Job plus a readiness-gated Deployment
would reproduce the same property on the GitOps path "for free," reasoning
that ArgoCD's health check for a Deployment already considers pod
readiness. That assumption was wrong, and finding out why live is its own
decision — see "Migration ordering (ArgoCD): sync-waves, not hooks" below.

**Consequence.** The plain-Helm migration Job's `helm.sh/hook-delete-policy`
includes `before-hook-creation` — a leftover Job from a prior failed
attempt otherwise blocks every subsequent retry with a stale "resource not
ready" error, which is exactly what happened while diagnosing this on a
live cluster. Deliberately *not* included: `hook-failed` — a failed
migration Job must survive so `kubectl logs` on it is still possible for
debugging; the next `before-hook-creation` cleans it up on the next
attempt anyway.

## Migration ordering (ArgoCD): sync-waves, not hooks

**Problem.** Round 1's plain-Helm answer — a `post-install` hook plus a
readiness-gated app — was assumed to translate directly to ArgoCD as a
`PostSync` hook. It doesn't, and the reason is specific to how ArgoCD's
sync operation is structured, not a variant of the round-1 problem.
Applying `gitops/application.yaml` against a real (public) repo on a live
cluster, the sync got stuck indefinitely: `kubectl logs` on the
application-controller showed `"waiting for healthy state of
apps/Deployment/reference-stack-app"`, repeated forever. The cause: a
`PostSync` hook runs only *after* ArgoCD's main sync wave reports every
resource Healthy — including the app Deployment. But the Deployment can
only become Healthy once `/readyz` returns 200, which depends on the
migration Job having run, which is the `PostSync` hook that hasn't run yet
because the Deployment isn't Healthy. Unlike the plain-Helm path, there is
no `--wait` flag to remove here: ArgoCD's sync operation always waits for
wave health before advancing to the next phase or hook — that behavior is
load-bearing to how ArgoCD works, not an optional flag.

The first fix attempted was moving the Job to a `PreSync` hook instead,
reasoning that `PreSync` runs *before* ArgoCD checks the main wave's
health, so the deadlock couldn't occur. That's true, but it reproduces
round 1's original problem one level down: `PreSync` runs before *any*
ordinary resource in the release exists — Postgres, the Secret, the
ConfigMap — so the Job's `envFrom` referencing the Secret would fail
outright (no Postgres to wait for, and no credentials to wait with).

**Options considered.**

1. **`PreSync` hook, with Secret/ConfigMap also promoted to `PreSync`.**
   Rejected before implementation: it still leaves the migration Job
   racing Postgres, which remains an ordinary (non-hook) resource for the
   reasons in round 1 option 1 (a hook Postgres StatefulSet risks its
   PVC). On a first sync, `wait-for-postgres` would poll a Service that
   ArgoCD hasn't created yet, with nothing in that phase bringing it up —
   an unbounded wait, not a bounded retry.

2. **Keep `PostSync`, add a custom ArgoCD health check** (a `health.lua`
   script in `argocd-cm` that considers the Deployment healthy without
   waiting on live pod readiness). Rejected: it works around the deadlock
   by making ArgoCD's health signal for a Deployment mean something
   different globally, for every Application on the cluster, not just
   this one. That's cluster-wide ArgoCD configuration living outside the
   chart entirely, for a reference stack whose entire premise is
   `make cluster && make install` reproducing the same result from
   nothing but this repository.

3. **Ordinary resources with `argocd.argoproj.io/sync-wave` annotations,
   no hooks at all.** Chosen. Wave `-2`: Secret, ConfigMap. Wave `-1`:
   Postgres StatefulSet + Service, Redis Deployment + Service. Wave `0`:
   the migration Job. Wave `1`: the app Deployment + Service. ArgoCD's
   sync operation waits for each wave to report Healthy before starting
   the next — for a Job, Healthy means Completed — so the app Deployment
   is never even *created* until the migration Job has finished. No hook
   phase, no health-check override, no deadlock: this is ArgoCD's native
   ordering mechanism operating on the normal reconciliation flow, applied
   to resources that are ordinary parts of the release the whole time.

**Why this is the right shape, not just the option that happened to
work.** Hooks (`PreSync`/`PostSync`/etc.) exist for work that has to
happen *outside* ArgoCD's normal declarative reconciliation — a Slack
notification, an external system call, something that isn't itself a
piece of desired state ArgoCD should track and heal. A schema migration
that gates the application is not that: it's an ordering constraint on
resources that already are part of desired state, and ArgoCD's own
ordering primitive for exactly that situation is sync-waves. Reaching for
a hook here was solving an ordering problem with the wrong tool, discovered
only by running it against a real cluster — the round-1 plain-Helm
answer (hook + readiness gate) is correct there specifically because Helm
hooks are the *only* ordering primitive Helm offers relative to `--wait`;
ArgoCD offers a better-fitting one, and the right answer is the one that
matches the tool, not the one that was correct on the other path.

**Consequence.** The plain-Helm and ArgoCD paths now use genuinely
different mechanisms for the same ordering goal, and that asymmetry is
correct, not something to "fix" into looking the same: `docs/decisions.md`
is exactly where that asymmetry is meant to be recorded so it doesn't get
silently "cleaned up" into a shared hook-based approach that reintroduces
this deadlock. `job.yaml` (plain-Helm) still uses the post-install hook
from round 1; `argocd-job.yaml` uses sync-waves and has no hook annotation
at all.

## Migration ordering (round 2)

**Problem.** Round 1's fix (post-install/post-upgrade hook, readiness-gated
app) rendered cleanly and passed `helm lint`/`helm template`, but deadlocked
on the very next live install: `helm upgrade --install ... --wait` failed
with `resource Deployment/default/reference-stack-app not ready`, and no
new migration Job had even been created. The cause is a second ordering
subtlety in Helm's hook lifecycle, symmetrical to round 1's: `--wait` blocks
until every *ordinary* resource in the release (including the app
Deployment) reports ready — and it does this **before** Helm runs
post-install hooks, not after. But the Deployment's readiness now depends
on `/readyz`, which depends on the post-install migration Job having run.
Round 1 fixed a hook that ran too early, relative to resources it depended
on; round 2 hit a wait that ran too early, relative to a hook it depended
on. Same underlying lesson twice: Helm's install phases (hooks pre-X,
ordinary resources, `--wait`, hooks post-X) are not one linear pipeline
where "later" always means "after everything earlier" — hooks and
`--wait` on ordinary resources are separate mechanisms that can each
block on the other if you're not careful which one you lean on.

**Options considered.**

1. **Move the Job back to pre-install**, but this time also make
   Postgres/Secret/ConfigMap pre-install hooks with a lower weight, so the
   Job has something to wait on. Rejected outright — this is round 1's
   rejected option 1, and the same problem applies: it turns Postgres's
   StatefulSet into a hook resource and risks its PVC's lifecycle. Round 2
   existing at all doesn't make that risk any more acceptable than it was
   in round 1.

2. **Drop `--wait` from `make install`; make `make verify` the thing that
   explicitly waits**, via `kubectl wait --for=condition=complete job/...`
   followed by `kubectl rollout status deployment/...`. Chosen. `make
   install` now does exactly what its name says — applies the desired
   state — and gets out of the way immediately once Helm has submitted it,
   instead of also trying to be a readiness-polling tool with a timeout
   budget shared awkwardly across hooks and ordinary resources. `make
   verify` already existed specifically to assert runtime behavior; moving
   the wait there means there is exactly one place in the repo responsible
   for "block until the release has actually converged," instead of two
   mechanisms (`--wait` and the migration Job's own hook lifecycle)
   racing each other.

**Why this is correct, not just working around the deadlock.** `--wait`
existing at all is Helm's own concession that "resources applied" and
"stack actually usable" are different moments — asking it to also
reconcile that gap with the hook lifecycle in the same call was overloading
one flag with two jobs. Splitting them mirrors the two commands' actual
responsibilities: `install` changes state, `verify` proves it converged.
This is also strictly more informative on failure — `make verify` waiting
explicitly on the Job first means a broken migration reports as "migration
Job did not complete" from `kubectl logs job/...`, not as an opaque
`Deployment not ready` from `--wait` with no indication that the real
cause lives one hop upstream.

**Consequence.** The migration Job's `activeDeadlineSeconds` moved from
120s to 300s: with `--wait` no longer providing an outer timeout on the
whole install, the Job's own deadline is the sole backstop against a hung
migration, so it needs enough headroom for a cold-starting Postgres rather
than sharing a budget with `--wait`'s 180s.

## Liveness vs readiness

**Problem.** With a single `/healthz` endpoint serving both the liveness
and readiness probes, making it schema-aware (checking that the `items`
table exists, per the migration-ordering decision above) would have made
the *liveness* probe fail for as long as the migration Job takes to run.
Kubernetes restarts a pod that fails its liveness probe. A pod that is
alive and waiting on a dependency is not broken — restarting it doesn't
make Postgres migrate any faster, it just adds pod-restart churn on top of
an already-slow startup, and in a worse case (a liveness probe with a low
failure threshold) could put the pod in a restart loop that never gives
the migration Job time to finish.

**Options considered.**

1. **Keep one `/healthz` endpoint, give liveness and readiness different
   probe timings** (e.g. a high `failureThreshold` on liveness so it
   tolerates a slow migration). Rejected: this masks the problem with
   configuration instead of fixing the contract. A liveness probe with a
   5-minute failure tolerance no longer functions as a liveness check for
   its actual purpose (catching a truly hung process) — it just delays the
   symptom. A reviewer reading `failureThreshold: 30` on a liveness probe
   has to go figure out why, instead of the probe's existence already
   telling the story.

2. **Keep `/healthz` dependency-free, do the readiness check with an
   `exec` probe** (e.g. shelling out to `curl` or a script inside the
   container). Rejected: it correctly separates the two concerns, but
   pulls in a shell/curl dependency inside the container image purely to
   do what an HTTP probe already does natively, for no benefit over just
   adding a second endpoint.

3. **Two endpoints: `/healthz` (liveness, always 200, no I/O) and
   `/readyz` (readiness, checks schema presence and pings Postgres/Redis,
   503 until both are true).** Chosen — going from 2 endpoints to 3 is a
   five-line addition, not a scope expansion. It's also the standard
   Kubernetes pattern for exactly this situation: liveness answers "is the
   process alive", readiness answers "can this pod serve traffic right
   now", and conflating them into one endpoint is what causes exactly the
   restart-loop failure mode
   this decision avoids.

**Consequence.** `/readyz` is also what makes the plain-Helm migration-
ordering decision work without any hook-weight coordination: it's the
single point where "has the schema been created yet" is actually checked,
and every consumer of pod readiness (the Service's endpoints, `helm
install --wait`) gets the correct answer for free. On the ArgoCD path,
ordering is instead handled by sync-waves (see "Migration ordering
(ArgoCD): sync-waves, not hooks") — `/readyz` is redundant there (the app
Deployment isn't even created until the Job completes) but stays in place
because it's harmless and keeps the endpoint's behavior identical across
both paths.

## PVC lifecycle

**Problem.** Found while re-verifying the SOPS setup: rotating
`secrets/secrets.enc.yaml`'s `postgresPassword` and running `helm upgrade
--install` against an *existing* release produced a confusing failure —
the migration Job's `wait-for-postgres` initContainer succeeded (Postgres
was reachable), but the migration container itself failed with `password
authentication failed for user "referencestack"`. The new password was
correctly decrypted and passed to the Secret and to Postgres's
`POSTGRES_PASSWORD` env var. The cause: the official `postgres` image only
runs its first-boot init scripts — which is where `POSTGRES_PASSWORD` gets
applied — when `PGDATA` is empty. On a second boot against an existing PVC
(any `helm upgrade`, or a fresh `helm install` after a `helm uninstall`
that left the PVC behind), the env var is silently ignored and the
database keeps whatever password it was initialized with. `helm
uninstall` deliberately does not delete PVCs bound to a StatefulSet — that
default exists specifically to stop an accidental uninstall from
destroying data — so this is the expected, if surprising, consequence of
that default combined with a password rotation.

**Options considered.**

1. **Leave PVC deletion out of `make uninstall`**, matching Helm's own
   default, and only document the gotcha. Rejected: this is a reference
   stack whose whole purpose is to be installed, torn down, and
   reinstalled repeatedly on a laptop while learning from it. Silently
   leaving stale state behind after `make uninstall` — the command whose
   name says "clean up" — contradicts what a reader will reasonably expect
   `make uninstall && make install` to do, and the failure mode (a
   password-auth error with no mention of PVCs anywhere in it) gives no
   hint toward the actual cause.

2. **`make uninstall` deletes the release's PVC(s) explicitly.** Chosen.
   `kubectl delete pvc -l app.kubernetes.io/instance=<release>` after
   `helm uninstall`, so `make uninstall && make install` behaves like a
   genuine fresh install — which is what this repo's own quickstart
   implicitly promises. This is explicitly the *opposite* of what's
   correct for a production release: a real Postgres holds real data, and
   `helm uninstall` not touching its PVC is a safety property you want,
   not a gap to route around. The Makefile comment on the `uninstall`
   target says this explicitly, so nobody copies this pattern into a
   production chart without noticing the trade-off was made on purpose for
   a disposable dev/demo stack.

**Consequence.** `make destroy` (delete the whole kind cluster) has always
had this property implicitly, since it removes the PVC's backing storage
along with everything else — `make uninstall` now matches that same
"fully torn down" expectation at the release level instead of only at the
cluster level. Rotating `secrets/secrets.enc.yaml` and expecting the new
value to take effect now requires `make uninstall && make install` (full
PVC-cleaning cycle), not `make install` alone (`helm upgrade`, PVC
untouched) — worth remembering as a reader, since `helm upgrade` alone
will keep silently using the old password.
