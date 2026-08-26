# Changelog

## 0.9.0 — 2026-08-26

### Parallel builds no longer wait for a whole batch

`--build-concurrency` chunked the build list into fixed batches and ran them
one batch at a time, so a slot freed by a fast build sat idle until its
slowest batch-mate finished. Measured on a four-service deploy at the default
concurrency of 2: a 3-minute build and a 7-minute build shared the first
batch, and the 8-minute build behind them did not start until minute 7 — the
group took 15 minutes where 9 were possible.

It is now a rolling pool: the next queued build starts the moment any build
finishes. Queue order is unchanged (the topo order), and the deploy phase
still runs strictly in dependency order — only the idle slots are gone.

On failure, no further builds are started, but the ones already in flight are
still awaited rather than abandoned mid-write.

### Concurrent build output says which service it came from

Builds streamed raw port chunks to a shared stdout, so several concurrent
builds interleaved — sometimes within a single line — with nothing to
attribute a line to a service. Deciphering "which of these four builds took
186 seconds?" meant correlating timestamps by hand.

Local streamed output is now buffered to line boundaries and each line is
tagged `[service] ` while builds run concurrently. The sequential deploy phase
is unchanged; it already announces each service before acting.

### Fixed: group mode built `deploy_only` services

A multi-config deploy ran `docker buildx build` for every service in the set,
including those marked `deploy_only` (or `local_image`) — services that have
no source and whose image comes from elsewhere. The build ran in a directory
with no Dockerfile, failed, and took the whole deploy down with it. Single-
config deploys had honoured the flag since it was introduced; group mode
computed "does this have a build step?" from the pipeline alone and never
consulted the config.

### `tag:` — per-service version in a multi-config deploy

`-t/--tag` is a single global flag. A deploy set mixing services built from
source with `deploy_only` ones could therefore not be expressed in one
invocation: the deploy-only services have no build context and so no git sha
to version from, but pinning `-t` on their behalf also pins — and mis-tags —
every service built from source. The result was one `ginger deploy` per
service, serialised, which throws away the parallel builds that multi-config
deploys exist for.

```yaml
tag: latest    # used when -t is not given
```

Precedence is `-t` > `tag:` > git sha of the build context.

### `nomad.var_file` — job specs can stay plain HCL

Job-template mode passed exactly one variable, the image ref. Everything else
that varies per environment — domains, registry host, node IP, registry
credentials — had nowhere to go, so the spec had to be a *template* that the
operator rendered before every deploy. That is not a hypothetical: a set of
`.hcl.erb` files existed solely because ginger offered no other way to get a
hostname into a `tags` or `extra_hosts` field, neither of which a Nomad
`template` stanza can reach (they are job-level fields, not runtime env).

A rendered spec is worse than a plain one in ways that bite: `nomad job
validate` cannot read it, neither can anyone reviewing a diff, and "did I
re-render before deploying?" becomes a real failure mode.

```yaml
nomad:
  job_file: /srv/app/web.nomad.hcl
  var_file: /srv/app/deploy.vars   # new; optional
```

becomes `nomad job run -var-file=/srv/app/deploy.vars -var image=… <job_file>`.
Both paths are resolved by the remote `nomad` CLI, not by ginger. The image
`-var` is emitted *after* the var file so it wins over any stale value there.

Omitted, nothing changes — no `-var-file` appears on the command line.

## 0.8.0 — 2026-08-11

Driven by two deploys that went wrong in ways the output did not admit to: one
that shipped when it had been asked a question, and one that reported success
while quietly corrupting a secret.

**One deliberate behaviour change**: an unrecognised flag is now a usage error
instead of being folded into the positional arguments. Anything that relied on
ginger ignoring a typo will now stop — which is the point, since what it did
instead was deploy to the wrong environment.

### Non-ASCII values survive the deploy instead of arriving double-encoded

An injected secret containing anything outside ASCII reached the container
corrupted. A Chinese SMS 签名 — `深圳市岑赫科技`, `E6 B7 B1 …` — arrived as
`C3 A6 C2 B7 C2 B1 …`, the same bytes re-encoded one at a time, and every SMS
the service tried to send came back `isv.SMS_SIGNATURE_ILLEGAL`.

The cause is not in the dotenv parser or the JSON job spec, both of which
handle UTF-8 correctly. It is `env_ffi`: `open_port/2` with `spawn_executable`
encodes each element of `args` according to `file:native_name_encoding()`,
which is `utf8` on macOS and modern Linux. Passing `binary_to_list/1` hands it
the UTF-8 *bytes* as though each were a codepoint, so every byte is encoded
again on the way out. Decoding to codepoints first (`unicode:characters_to_list`)
makes the round trip lossless.

The failure mode is what made this worth chasing: the deploy reports success,
nothing in its output mentions the value, and the service fails at runtime
with an error naming neither ginger nor encoding.

`os:getenv/0` got the mirror-image fix. It returns codepoints under a utf8 name
encoding, so `list_to_binary/1` would have crashed with `badarg` on a non-ASCII
value in the process environment rather than merely corrupting it.

Fixed in `local_exec/1`, `local_exec_stream/1`, `git_sha/1` (a non-ASCII repo
path) and `read_file/1` (a non-ASCII config path).

### Unknown flags are refused instead of silently ignored

Found by running `ginger deploy --help` and watching it start a real deploy.

`--help` was only recognised as the *first* word, and the argument parser's
catch-all turned every token it did not know into a positional. So
`["deploy", "--help"]` matched the deploy arm and shipped. The same hole made
a typo dangerous in a much quieter way:

```
ginger deploy --conifg ginger.cn.yml   # deployed to ginger.yml — a different environment
ginger deploy -c                       # ran the pipeline named "-c"
ginger logs --tail abc                 # printed 100 lines, having asked for "abc"
```

In each case the flag and its value vanished into the positional list, where
only the first element is ever read, and the command ran with defaults.

Now:

- an unrecognised `-x`/`--xyz` is a usage error, exit 1;
- `--help`/`-h` and `--version` are accepted anywhere and outrank the command
  on the line, so `ginger deploy --help` is always a question;
- a value-taking flag with nothing after it is an error, not a positional;
- `--tail`/`--build-concurrency` reject non-numeric and non-positive values
  rather than falling back to the default;
- `--` ends flag parsing, for a pipeline or rollback target starting with `-`.

No valid invocation changes behaviour.

### Deploy output says where it is going, and what took the time

The transcript opened with `Running pipeline: deploy` and never named the
environment — with `ginger.yml` and `ginger.cn.yml` side by side in a repo and
`-c` selecting between them, the first hint of which one was in play used to be
a hostname several lines down. There were no durations at all, so "why was that
deploy slow" could not be answered without running it again.

```
▸ deploy soon
  config   ginger.cn.yml
  target   juluo.xyz
  version  f25f7fa
  ...
  ✓ build            1m 12s
  ✓ lock               412ms
  ✓ release             21s
  total              1m 34s
```

Durations are monotonic-clock based, so an NTP correction mid-deploy cannot
report a step as instantaneous. The closing line is the total only — each step
already printed its own, and a build's line lands directly under the buildx
output it measured, so re-listing them would double the report without adding
a fact.

### `local_image:` — deploy an image that is in no registry

Driven by bootstrapping a self-hosted registry (yatch) on homepod: the registry
cannot pull its own image from itself.

```yaml
local_image: true     # built straight into the target host's Docker daemon
```

`deploy_only` was not enough. It drops `Build`/`Push`, but `boot-app` still ran
`docker login` and pre-pulled the image, and both fail when nothing is behind
the reference:

```
Error response from daemon: pull access denied for yatch, repository does not
exist or may require 'docker login'
```

The two flags now mean different things — `deploy_only` is *"already in the
registry"*, `local_image` is *"never in a registry at all"*. `local_image`
implies `deploy_only` and additionally:

- skips the remote `docker login` (both boot paths),
- skips the pre-pull,
- omits registry auth from the generated Nomad task config,
- makes `registry:` optional — previously a missing block was a hard error, so
  operators had to invent placeholder credentials,
- prints `registry: (none — local_image: ...)` in `ginger config` rather than
  credentials a deploy never uses.

Build with `DOCKER_HOST=ssh://user@host docker build --platform linux/amd64 -t
app:v1 .`, then `ginger deploy -t v1`. **The build tag and `-t` must match** —
nothing resolves the image for you.

Backward compatible: defaults to `false`, and every existing behaviour is
unchanged when unset.

## 0.7.0 — 2026-07-26

Driven by moving the xjdao.xyz stack (8 services, Nomad + Traefik on a single
Aliyun host) onto ginger. **Backward compatible**: the new `nomad:` block is
optional and absent means exactly 0.6.0 behaviour.

### Nomad job-template mode (`IMPROVEMENTS.md` §3.2)

Deploy a hand-written Nomad job spec instead of the one ginger generates:

```yaml
runner: nomad
nomad:
  job_file: /srv/xjdao/deploy/nomad/social-app.nomad.hcl  # path on the deploy host
  job_id: social-app        # optional, defaults to `service`
  image_var: image          # optional, defaults to "image"
```

ginger logs into the registry, pre-pulls the image, then runs
`nomad job run -var <image_var>=<repo>:<sha> <job_file>` and **health-gates the
deployment** exactly as it does for generated specs — polling
`nomad job deployments -latest` and dumping the failing allocation's stderr on
failure.

Why this matters: the previous way to deploy a real job spec was
`hook: nomad job run … && nomad job restart …`. A hook reports success the
moment the command exits, so a job whose allocations crash-loop still
"deploys" successfully. Job-template mode keeps the operator's HCL *and*
ginger's health gate.

Passing the image as an HCL2 variable also sidesteps the `:latest` no-op trap —
a sha-tagged ref changes the job definition every deploy, so Nomad actually
rolls it out instead of treating the submission as unchanged. The spec must
declare the variable:

```hcl
variable "image" { type = string }
task "web" { config { image = var.image } }
```

`job_id` exists because a hand-written spec is named whatever `job "..."` the
operator wrote, not `<service>-<role>`; status, logs and the health gate all
address that ID.

### `deploy_only: true`

For services whose image comes from elsewhere (an upstream registry, another
pipeline), drop `Build`/`Push` from every pipeline — the same effect as
`--skip-push`, but declared once in the config:

```yaml
deploy_only: true
```

Previously such a service either failed in `docker buildx` (no build context)
or forced the operator to hand-write a pipeline just to omit two steps. Note
that without a `builder.context` ginger cannot derive a version from git, so
these configs need an explicit `-t <tag>`.

### `ginger config`

Now prints the resolved job-template settings, so it is possible to tell at a
glance whether a config deploys its own spec or ginger's generated one.

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
