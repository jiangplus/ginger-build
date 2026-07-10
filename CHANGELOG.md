# Changelog

## 0.6.0 — 2026-07-02

Driven by deploying a real 6-service AT Protocol stack (see `IMPROVEMENTS.md`
for the full findings). **Backward compatible**: every new config field is
optional with a default that matches 0.5.0 behaviour — existing `ginger.yml`
files work unchanged. The one behaviour change is the build-cache default
(see below).

### Build

- `builder.context` — build-context directory (default `.`). The git sha used
  as the version tag is now resolved from this directory, so configs living
  outside the repo version from the code they build.
- `builder.dockerfile` — Dockerfile path relative to the context
  (`docker build -f`); monorepo builds no longer need hook-based workarounds.
- `builder.tags: [latest]` — extra tags pushed alongside the version tag, so
  `:latest`-pinned runtime specs and versioned rollback history coexist.
- `builder.cache: none|min|max` — registry build-cache policy.
  **Default changed from `mode=max` to `mode=min`**: max exported every
  intermediate layer on every deploy (165 s of a 7-minute real-world build);
  set `cache: max` to restore the old behaviour.
- Provenance attestations and SBOM are now disabled by default
  (`--provenance=false --sbom=false`) — they add export time and extra
  manifests that simple registries may not expect. Set
  `builder.provenance: true` to restore buildx's default.

### Multi-service deploys

- `-c` is repeatable: `ginger deploy -c a.yml -c b.yml -c c.yml` deploys a
  group. Each config stays an independent file — there is no stack file.
- `deps: [../other.yml]` (paths relative to the config file) orders the group:
  deploys run sequentially in dependency order; a dep outside the deploy set
  is ignored; cycles are a config error.
- Builds in a group run in parallel, capped by `--build-concurrency`
  (default 2 — builds are memory-hungry; keep the cap modest).

### Container options (both runtimes)

- `volumes: ["host:container"]`, `extra_hosts: ["name:ip"]`, and free-form
  `labels:` maps pass through to `docker run` and the Nomad docker task.
- `resources: {cpu: MHz, memory: MB}` — Nomad task resources (previously
  hardcoded to 256/512, which could fail scheduling on bin-packed nodes).

### Monitoring & error feedback

- Remote hook output is now printed (with a `[host]` prefix) instead of being
  discarded on success — `status:`/`logs:`-style pipelines are actually usable.
- `ssh.command_timeout` (seconds, default 600 — up from a hard 300) sets the
  deadline for all remote commands; hooks accept a per-step
  `timeout:` override for long on-server builds.
- On a failed Nomad deployment, ginger automatically tails the failing
  allocation's stderr (last 40 lines) into the error message.

### New commands

- `ginger logs [-f|--follow] [--tail N]` — service logs per host
  (`nomad alloc logs` / `docker logs`); `--follow` streams live over SSH.
- `ginger history [--tail N]` — deploy audit log. Every successful boot-app
  appends `<utc-time> service=<s> version=<v> image=<ref>` to
  `.ginger/history-<service>.log` on the primary host, making
  `rollback <version>` discoverable.
- `ginger status` on the Nomad runtime now shows `nomad job status` per host
  (it previously only understood the docker/kamal-proxy layout).

### CLI

- Global flags are accepted anywhere: `ginger -c x.yml deploy` now works
  (0.5.0 silently ignored pre-command flags and read `./ginger.yml`).
- A pipeline named `status`, `logs`, or `history` in the config takes
  precedence over the built-in command (0.5.0's built-in `status` silently
  shadowed user pipelines).
- `ginger rollback` / `ginger run` without their argument now error instead
  of misrouting.

## 0.5.0

Initial public escript: Nomad+Traefik / Docker+kamal-proxy runners, explicit
pipelines, inline hooks, auto-env secrets, rolling updates, proxy reuse,
registry build cache, `push_registry` mirror support.
