---
name: ginger
description: >
  Set up and use ginger — a Gleam/BEAM container deployment tool similar to Kamal.
  Use this skill whenever the user wants to: install ginger, create a ginger.yml,
  deploy a containerised app with ginger, deploy several services together,
  configure the proxy or secrets, view logs or deploy history, roll back
  a deployment, or troubleshoot a ginger deploy failure. Also trigger when the user
  mentions "ginger deploy", "ginger.yml", or asks how to get ginger running on a
  new server or project.
---

# ginger deployment skill

ginger is a single-binary deployment tool (Gleam/OTP escript) that builds a Docker
image, pushes it to a registry, and rolls it out over SSH with zero downtime.

Default stack: **Nomad** (container scheduling) + **Traefik** (traffic routing).
Alternative: **Docker** + **kamal-proxy** — two YAML lines to switch.

Release page: https://github.com/jiangplus/ginger-build/releases
Current version: **0.6.0** (see CHANGELOG.md in the repo for what's new).

---

## Step 1 — Install Erlang/OTP 27+

ginger is an escript and needs Erlang on the operator machine. OTP 27 is the minimum.

**Detect what's installed first:**
```sh
erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell
```
If this prints 27, 28, or 29 — skip to Step 2.

**macOS**
```sh
brew install erlang
```

**Ubuntu / Debian** — the system `apt` package is too old; use Erlang Solutions:
```sh
wget -qO- https://packages.erlang-solutions.com/ubuntu/erlang_solutions.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/erlang-solutions.gpg
echo "deb [signed-by=/usr/share/keyrings/erlang-solutions.gpg] \
  https://packages.erlang-solutions.com/ubuntu $(lsb_release -cs) contrib" \
  | sudo tee /etc/apt/sources.list.d/erlang-solutions.list
sudo apt update && sudo apt install -y esl-erlang
```

**Windows** — download the OTP 27+ `.exe` from https://www.erlang.org/downloads and
install it inside WSL2 (Ubuntu). ginger's SSH features require a POSIX shell
environment; run everything from WSL2.

---

## Step 2 — Install ginger

Download the pre-built escript and make it executable:

```sh
curl -fsSL https://github.com/jiangplus/ginger-build/releases/latest/download/ginger \
  -o ~/.local/bin/ginger
chmod +x ~/.local/bin/ginger
ginger version   # should print: ginger 0.6.0
```

Or build from source (requires Gleam and just): `git clone … && cd ginger && just install`.

Make sure the install dir is on your PATH.

---

## Step 3 — Create `ginger.yml`

Ask the user which stack they want, then fill in the matching template.

### Nomad + Traefik (default)

ginger submits a Nomad job; Traefik auto-discovers it via Docker labels. No Traefik
registration step needed — start the container and routing begins automatically.

```yaml
service: myapp                        # container name prefix [a-z0-9_-]
image: ghcr.io/myorg/myapp            # image name (tag = git SHA by default)

# runner: nomad and egress: traefik are the defaults — you can omit these two lines
runner: nomad
egress: traefik

servers:
  web:
    hosts: [10.0.0.1]                 # SSH-accessible server IPs or hostnames
    primary: true

registry:
  server: ghcr.io
  username: myorg
  password: GITHUB_TOKEN              # name of the env var / .env key

proxy:
  hosts: [myapp.example.com]          # domain(s) Traefik will route to this service
  app_port: 3000                      # port the container listens on
  ssl: true                           # Traefik handles Let's Encrypt automatically
  health_check_path: /up

ssh:
  user: root
  command_timeout: 600                # seconds; deadline for remote commands/hooks

builder:                              # all optional
  arch: amd64
  remote: ssh://docker@builder        # omit to build locally with docker buildx
  context: .                          # build-context dir; git-sha version comes from here
  dockerfile: cmd/app/Dockerfile      # relative to context (monorepo builds)
  tags: [latest]                      # extra tags pushed alongside the version tag
  cache: min                          # registry build cache: none | min (default) | max
  provenance: false                   # attestations+SBOM off by default (faster)

env:
  NODE_ENV: production

secrets:
  load: [.env]
  inject:
    - GITHUB_TOKEN
    - "DATABASE_*"

# Container plumbing passthroughs (both runtimes; all optional)
volumes:
  - /opt/myapp/data:/data
extra_hosts:
  - internal.example.com:10.0.0.9
labels:
  team: platform
resources:                            # Nomad task resources (MHz / MB)
  cpu: 256
  memory: 512

# Other services this one depends on (for multi-config deploys; paths are
# relative to THIS config file)
deps:
  - ../db/ginger.yml

rolling:
  limit: 25%                          # hosts per batch: integer or percentage
  wait: 5                             # seconds between batches
  parallel_roles: false
retain_containers: 5
```

### Docker + kamal-proxy

Same file, plus:

```yaml
runner: docker
egress: kamal-proxy
proxy:
  hosts: [myapp.example.com]
  app_port: 3000
  ssl: true
  health_check_path: /up
  deploy_timeout: 30
  drain_timeout: 30
```

**Key questions to ask the user before filling this in:**
- Nomad+Traefik or Docker+kamal-proxy?
- Service name, image path, registry?
- Server IPs and SSH user? Domain? Container port?
- Monorepo? (→ set `builder.context` / `builder.dockerfile`)
- Do runtime specs pin `:latest`? (→ add `builder.tags: [latest]`)
- Secrets to inject?

---

## Step 4 — Set up secrets

ginger reads secrets from the process environment and `.env` files — never from the
YAML directly:

```sh
# .env (gitignored)
GITHUB_TOKEN=ghp_xxxxxxxxxxxx
```

Check with `ginger config -c ginger.yml` (secrets redacted; flags may go anywhere).

---

## Step 5 — Deploy

```sh
ginger deploy                      # build, push, deploy with zero downtime
ginger deploy -c a.yml -c b.yml    # GROUP deploy: repeat -c for several services;
                                   #   builds run in parallel (cap 2), deploys
                                   #   follow each config's deps: order
ginger deploy --skip-push          # skip build; deploy whatever is in the registry
ginger deploy --tag v1.2.3         # pin a specific image tag instead of git SHA
ginger redeploy                    # deploy without touching the proxy or pruning
ginger rollback <version>          # switch traffic back to an older container
ginger remove                      # stop all containers / purge Nomad jobs
ginger status                      # job/container status per host
ginger logs [-f] [--tail N]        # service logs per host; -f streams live
ginger history [--tail N]          # deploy audit log from the primary host
ginger run <pipeline>              # run a custom named pipeline from ginger.yml
ginger lock release|status|acquire # deploy mutex management
ginger config                      # print parsed config (secrets redacted)
```

**Global options (any command, any position):**

| Flag | Default | Description |
|------|---------|-------------|
| `-c, --config <file>` | `ginger.yml` | Config file; repeatable → group deploy |
| `-P, --skip-push` | false | Skip image build/push |
| `-t, --tag <version>` | git SHA | Pin the image tag |
| `--build-concurrency <n>` | 2 | Parallel builds in group deploys (keep modest — builds are memory-hungry) |
| `-f, --follow` | false | Follow logs |
| `--tail <n>` | 100 | Lines for `logs` / `history` |

A pipeline in the config with the same name as a command (`status`, `logs`,
`history`, `deploy`, ...) takes precedence over the built-in behaviour. Any other
first argument is a custom pipeline name (`ginger run <name>` is the explicit form).

### Multi-service groups

There is deliberately no stack file. Each service keeps its own `ginger.yml`;
`deps:` entries (paths relative to the config file) link them. Deploying with
repeated `-c` topo-sorts the set, builds in parallel, deploys sequentially in
dependency order. Deps pointing outside the deploy set are ignored. The deploy
lock is per-service, so unrelated services can deploy concurrently.

### Custom pipelines

```yaml
pipelines:
  deploy:
    - build
    - lock: acquire
    - hook: { run: 'nomad job run /srv/app.nomad.hcl', local: false, timeout: 900 }
    - lock: release
  status:
    - hook: { run: 'nomad job status myapp | head -40', local: false }
```

Steps: `build`, `push`, `boot-proxy`, `boot-app`, `remove-app`, `prune`,
`lock: acquire|release|status`, `hook: <cmd>` (string = local) or
`hook: { run, local, timeout }` (`local: false` runs on every host; `timeout`
in seconds overrides `ssh.command_timeout`). Hook output is shown live with a
`[host]` prefix.

---

## Troubleshooting

**"secrets.inject keys not set"** — a key listed under `secrets.inject` is missing or
empty. Export it or add it to `.env`.

**"SSH error: connect … timeout"** — server unreachable or wrong SSH user/key.
Test with `ssh <user>@<host>` directly.

**"deploy lock already held"** — a previous deploy crashed while holding the lock:
`ginger lock release`.

**Nomad deployment failed** — ginger automatically prints the failing allocation's
last 40 stderr lines. If a task is in crash-loop backoff after a bad image, a plain
re-run won't recover it — `nomad job stop -purge <job>` then deploy again.

**Monorepo build can't find files** — set `builder.context` to the repo root and
`builder.dockerfile` relative to it; ginger joins them for docker's cwd-relative `-f`.

**Dockerfile runs `git describe` / needs `.git`** — don't exclude `.git` in
`.dockerignore` for that image.

**Runtime spec pins `:latest` but deploys use git-sha tags** — add
`builder.tags: [latest]` so both are pushed; never rely on `--tag latest` alone
(it destroys rollback history).

**Group build failed for one service** — the group aborts before any deploy
(images already pushed are harmless). Fix and re-run; successful services' builds
hit the registry cache.

**"runner: nomad requires egress: traefik"** — only `nomad+traefik` and
`docker+kamal-proxy` are valid combinations.

**Traefik/kamal-proxy already running** — ginger detects and reuses any existing
proxy on the host; other apps served by it are never disrupted.
