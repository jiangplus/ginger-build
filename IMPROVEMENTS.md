# ginger improvements — findings from deploying the greenfield bsky stack

> **Status (0.6.0)**: most of the findings below are implemented — see
> `CHANGELOG.md`. Shipped: builder `context`/`dockerfile`/`tags`/`cache`,
> multi-config deploys with `deps:` ordering and capped parallel builds
> (`-c` repeatable, `--build-concurrency`), `volumes`/`extra_hosts`/`labels`/
> `resources` passthroughs, remote hook output display, `ssh.command_timeout`
> + per-hook `timeout:`, failed-deployment alloc-log auto-fetch,
> `ginger logs [-f]`, deploy history + `ginger history`, flags-anywhere CLI,
> pipeline-first `status`/`logs`/`history`. **0.7.0** adds job-template mode
(§3.2). Deliberately NOT built: a
> multi-service stack file — independent per-service configs with `deps:`
> references cover the greenfield case without a new config format; revisit
> only if a real stack outgrows that (e.g. shared env blocks or cross-service
> secret templating become painful). If that day comes, the agreed direction
> is a NEW file convention — `ginger.stack.yml` — with its own schema, rather
> than growing `ginger.yml` into a dual-mode format; per-service files stay
> the primary interface and a stack file would only reference them. Still open: job-template mode (§3.2),
> structured progress tree / summary table, `logs --grep/--since`, log-driver
> config, remote streaming for hook-based builds (hooks print on completion,
> not live).

Source: converting a real 6-service AT Protocol stack (postgres, plc, relay,
appview, pds, ouranos — Nomad + Traefik on a single Lightsail host) to
ginger-driven deploys (`greenfield-deploy/ginger/*.yml`). What worked, what
had to be worked around with custom pipelines + hooks, and what ginger should
grow to handle a *group* of services natively.

## 1. Multi-service stacks (the biggest gap)

ginger is one service per `ginger.yml`. A real stack is N services sharing a
host, a registry, SSH settings, and secrets — we ended up with 6 config files
that duplicate `servers:`, `registry:`, `ssh:`, `secrets:` blocks, and there
is no way to deploy or inspect the stack as a unit.

Proposal — a `services:` map in one file:

```yaml
stack: greenfield-bsky
registry: { server: yatch.greenfield.town, username: token, password: YATCH_TOKEN }
servers:
  web: { hosts: [13.193.117.178], primary: true }
ssh: { user: ubuntu }

services:
  postgres: { image: postgres:16, deploy_only: true, stateful: true }
  plc:      { image: ghcr.io/xjdao2025/did-method-plc, deploy_only: true, depends_on: [postgres] }
  relay:    { image: .../relay,   build: { context: ../bsky/indigo,  dockerfile: cmd/relay/Dockerfile }, depends_on: [plc] }
  appview:  { image: .../appview, build: { context: ../bsky/atproto, dockerfile: services/bsky-standalone/Dockerfile }, depends_on: [postgres, plc] }
  pds:      { image: ghcr.io/bluesky-social/pds, deploy_only: true, depends_on: [plc, appview] }
  ouranos:  { image: .../ouranos, build: { context: ../bsky/ouranos }, depends_on: [pds, appview] }
```

- `ginger deploy` → whole stack in dependency order; `ginger deploy ouranos` →
  one service.
- **Parallel builds**: builds of independent services should run concurrently
  (relay/appview/ouranos have no build-order dependency; we built them in
  parallel by hand earlier and it cut wall time ~3×). Erlang makes this
  natural — one process per build, multiplexed progress output (see §4).
- Deploys serialize per `depends_on`; independent siblings roll out in
  parallel (`parallel_roles` already exists — generalize it to services).

## 2. Build step is too rigid for monorepos

`build` always runs `docker buildx build … .` from cwd with the default
`Dockerfile`. Two of our three images build from a monorepo root with `-f`:

- appview: `-f services/bsky-standalone/Dockerfile` in `atproto/`
- relay: `-f cmd/relay/Dockerfile` in `indigo/`

Neither can use ginger's build step at all today — they fall back to
hook-based `rsync + ssh docker build`, which loses ginger's registry login,
caching, and tagging. Add to `builder:`:

```yaml
builder:
  context: .                # default cwd
  dockerfile: path/to/Dockerfile
  tags: [latest]            # extra tags pushed alongside the version tag
```

`tags: [latest]` matters because runtime specs commonly pin `:latest`; today
the only workaround is `ginger deploy --tag latest`, which then destroys
version history (every deploy overwrites the same tag → `rollback` has
nothing to roll back to). Push `:SHA` *and* `:latest` together.

Also two cache findings from the pilot (`gf-ouranos`, remote builder over
`DOCKER_HOST=ssh://`, which worked well):

- `--cache-to type=registry,mode=max` cost **165s of a ~7-minute build** —
  the cache export took longer than the push of the image itself. `mode=max`
  exports every intermediate layer on every deploy. Default to `mode=min`
  and/or add `builder.cache: false|min|max`.
- `--cache-to type=registry` is only supported when the daemon has the
  containerd image store (worked on greenfield's Docker 28); on older/plain
  daemons the export fails. Detect via `docker buildx inspect` and downgrade
  gracefully instead of failing the deploy.

## 3. Nomad job spec cannot express real jobs

The generated spec hardcodes exactly what our 6 jobs each needed to override:

| hardcoded in ginger | what the stack needs |
|---|---|
| dynamic ports only | static ports (Traefik file-provider routes to fixed host ports) |
| `CPU: 256, MemoryMB: 512` | per-service tuning (this host is CPU-bin-packed to ~99%; 256 would *fail scheduling*) |
| no volumes | postgres/pds/relay/appview persist host paths |
| no `extra_hosts` | loopback overrides for internal traffic (skip Cloudflare) |
| no template/Vault/nomadVar blocks | secrets via `nomadVar` templates |
| `Datacenters: ["dc1"]` | fine here, wrong elsewhere |

Two-tier fix:

1. **Passthrough fields** for common needs: `resources: {cpu, memory}`,
   `volumes: []`, `extra_hosts: []`, `static_port`, `datacenters`.
2. **Job-template mode** — ✅ **shipped in 0.7.0** as the `nomad:` block
   (`job_file` / `job_id` / `image_var`); see `CHANGELOG.md`. The design below
   is what was built, with the image passed as an HCL2 `-var` rather than a
   Nomad variable. Original proposal:

   ```yaml
   nomad:
     job_file: /srv/greenfield-bsky/gf-ouranos.nomad.hcl   # local or remote path
   ```

   ginger substitutes image/version (via `nomad var` or HCL2 `-var`), runs the
   job, and health-gates the deployment — this is exactly what our custom
   pipelines do by hand today with
   `hook: nomad job run … && nomad job restart …`, but hooks bypass ginger's
   health gate entirely (a broken image "deploys" successfully).

   Related trap: job specs pinning `:latest` don't re-pull on `nomad job run`
   (config unchanged → no-op). `force_pull: true` exists in ginger but only in
   its generated spec. Job-template mode should handle the
   run+restart-on-same-tag dance itself.

## 4. Monitoring and error feedback

- **Remote commands are silent until they finish** (`ssh.exec` captures
  stdout/stderr; success output is discarded). In the pilot, the step that
  actually deployed (`nomad job run … && nomad job restart …`) produced zero
  output — the transcript jumps from "Acquiring deploy lock" straight to
  "deploy complete", and we had to ssh in to confirm anything happened. A
  5-minute on-server `docker build` in a hook is worse: nothing on screen,
  indistinguishable from a hang.
  Local builds stream; remote should too (OTP ssh delivers channel data
  incrementally — stream lines with a `[host]` prefix, like `kamal`).
- **Hard 5-minute SSH timeout** (`executor.default_timeout`) with no
  per-step override. Remote monorepo builds on a cold cache exceed this and
  the deploy dies mid-flight *with the lock held*. Add
  `hook: { run: …, timeout: 1800 }` and a config-level default.
- **Progress structure**: with multiple services and steps, flat log lines
  won't scale. Emit a step tree (`[stack] [service] [step] status/duration`)
  and a final summary table: what was built, image digests, old→new versions,
  per-step wall time.
- **Failure context**: on `ExecError`, ginger prints the command and stderr —
  good — but for a failed *deployment* (Nomad gate) it should automatically
  fetch and print the failing allocation's last N log lines
  (`nomad alloc logs -stderr <failing alloc>`), not leave the operator to ssh
  in. That single feature would have saved the most debugging time in this
  project (every real failure ended with us running `docker logs` by hand).
- **Discarded hook output makes observability pipelines impossible**: we
  defined `check:` (nomad job status + health curl) and `logs:`
  (`docker logs --tail 100`) pipelines per service — they run and report
  "✓ complete" but display *nothing*, because remote hook stdout is thrown
  away on success. Hooks should print their output (at minimum with a
  `show: true` flag).
- **Built-in command names silently shadow custom pipelines**: `deploy`/
  `redeploy`/`rollback`/`remove` resolve config pipelines first, but `status`
  is hardcoded — a user-defined `status:` pipeline is unreachable and
  `ginger status` prints the built-in's `version=(none), proxy: none
  detected` (meaningless for hook-driven setups). Route all non-flag commands
  through pipeline resolution first, or error on the name collision.
- **CLI ergonomics**: global flags silently no-op before the command
  (`ginger -c file deploy` reads `./ginger.yml`; `ginger deploy -c file`
  works). Either support both orders or error on unknown pre-command args —
  silent fallback to the wrong config file is dangerous with production
  stacks.

## 5. Log management for debugging

Nothing exists today; we hand-defined `logs:` pipelines running
`docker logs --tail 100` per service. Built-ins worth having:

- `ginger logs [service] [--follow] [--since 1h] [--grep pat]` — resolve the
  service's current container/alloc on each host and stream with
  `[host/service]` prefixes. Nomad runner: `nomad alloc logs`; docker runner:
  `docker logs`.
- `ginger deploy` should end by printing *how* to see logs for what it just
  deployed.
- **Deploy audit log**: append a line per deploy (`when, who, service,
  old→new version, digest, result, duration`) to a file on the primary host
  (`/var/log/ginger/deploys.log`) and surface it as `ginger history` —
  today's `ginger rollback <version>` is unusable without a record of what
  versions exist and when they ran.
- Optional log shipping is out of scope, but a `logs` config block
  (`driver: json-file, max-size, max-file`) applied to generated specs would
  stop unbounded container log growth (bit us on another host).

## 6. Smaller findings

- `secrets.load` paths are cwd-relative, which interacts badly with "build
  context = cwd" — configs living outside the repo (our case:
  `greenfield-deploy/ginger/*.yml` with builds running from each repo) need
  `../../…/.env` paths. Resolve `load:` relative to the config file instead.
- Registry login for hook-based flows: hooks that `docker push` on the host
  rely on a pre-existing server-side `docker login`. If ginger knows the
  registry credentials it should offer a `login` step usable in pipelines
  (remote variant of what `build` already does locally).
- Deploy lock is per-service (`service-role` on primary host). For a stack,
  a stack-level lock is the right unit; per-service locks don't prevent two
  half-overlapping stack deploys.
- `parse_deployment_status` polls `nomad job deployments -latest` — with
  job-template mode it must tolerate jobs that have no `update` stanza (no
  deployment record is ever created → currently reads as eternal "pending").
