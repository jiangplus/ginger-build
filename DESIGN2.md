# ginger — Build & Deploy Performance

Why a Nomad + Traefik deploy feels slow, and how to make it fast. The headline:
**the slowness is mostly not Nomad or Traefik.** Breaking a deploy into phases
makes the real costs visible.

## Where the time goes

| Phase | Owner | Introduced by the Nomad+Traefik path? | Observed this bring-up |
|-------|-------|----------------------------------------|------------------------|
| Image build (buildx) | remote builder (`wamo.city`) | No — identical under kamal | cache-dependent |
| **Push to ghcr.io** | remote builder → registry | No | seastar-auth `pushing … DONE 152.5s` |
| Image pull on server | Nomad docker driver | Partly | per new allocation |
| Health / rolling wait | Nomad deployment | Yes | `MaxParallel:1` + ~10 min progress deadline |
| Failed-task backoff | Nomad restart/reschedule | Yes | `restarting in 16–18s`, exponential |

The single biggest time sink during bring-up was **re-deploying ~5× to chase
four ginger bugs plus the missing `GHCR_TOKEN`**, each failure waiting out
Nomad's backoff. That is a one-time debugging cost, not a steady-state property.

## What is genuinely new cost under Nomad + Traefik

1. **`redeploy` always rebuilds.** The `redeploy` pipeline includes `Build`, so
   every invocation rebuilds and re-pushes even when source is unchanged. Under
   the old kamal flow the image was already local, which is why swaps "felt
   instant."
2. **Each new allocation re-pulls the image.** Nomad does not reuse the prior
   container; a fresh alloc pulls from ghcr.io every deploy.
3. **A bad deploy can hang for the full progress deadline (~10 min)** before
   Nomad gives up, then backs off. Healthy deploys never hit this, but every
   failure during bring-up did.
4. **No real health check** means Nomad falls back to a default deployment
   health judgement, so the wait window is neither tight nor predictable.

## How to speed it up (by payoff)

### 1. Don't rebuild when the code hasn't changed — biggest win
`redeploy` runs `Build` unconditionally. When the source is unchanged, reuse the
already-pushed image (`ginger redeploy --skip-push`, as was done for sails) and
skip the entire build+push segment. Better: split build from deploy so `Build`
only runs when the git SHA changed, and the deploy step consumes an existing
tag.

### 2. Give buildx a registry layer cache
The remote builder's BuildKit cache is lost when the builder container restarts.
Add `--cache-from type=registry,ref=<image>:buildcache` and
`--cache-to type=registry,...` so the cache lives in ghcr.io and survives
builder restarts. The 152 s seen was dominated by the push; with a warm cache
unchanged layers are not re-transferred.

### 3. Fail fast — stop bad deploys from burning ~10 minutes
Set `Update.progress_deadline` in the Nomad job (e.g. 2 min) and emit a Nomad
service check built from `proxy.health_check_path`. A broken deploy then fails in
~2 min instead of ~10, and a healthy one converges the instant the check passes.
This doubles as the health-gating fix (see DESIGN.md #2/#3): ginger should poll
`nomad job deployments -latest` to `successful`/`failed` and map that to its exit
code. *(The job-spec encoder and a `deployment_status` command already exist; the
remaining work is wiring the check into the spec and the gate into the deploy.)*

### 4. Keep images warm on the Nomad client
The docker plugin is configured without image-GC tuning, so `nomad system gc`
can evict images that the next deploy re-pulls. Tune the docker plugin's
`gc.image`/`gc.image_delay` so recent images are retained; same-tag/new-digest
pulls are unavoidable, but shared layers are then reused.

### 5. Pre-pull on the target before submitting the job (optional)
After build+push and before `nomad job run`, `docker pull` once on the target
host (ginger already performs the registry login). The allocation then starts
with the image present and clears its health check sooner.

## Priority

Doing **#1 (skip build when unchanged)** alone takes a single-service deploy
from "minutes" down to "the few tens of seconds of pull + health check."
**#3 (fail-fast progress deadline + service check)** removes the 10-minute stall
whenever something is wrong. Those two are the highest leverage; #2, #4, #5
trim the remainder.
