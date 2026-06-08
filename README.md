# ginger

Deploy containers anywhere, in Gleam. A [Kamal](https://kamal-deploy.org)-class
deployment tool: build an image, push it to a registry, and roll it out across
your servers over SSH with zero downtime via [kamal-proxy](https://github.com/basecamp/kamal-proxy).

Compared to Kamal, ginger makes four deliberate choices:

1. **kamal-proxy** for zero-downtime traffic switching — reuses an already-running proxy on the host rather than booting a second one.
2. **Rolling updates** across multiple hosts and roles.
3. **Explicit actions in YAML** — deploy/redeploy/rollback/remove sequences are declared as named *pipelines* of built-in steps, not hardcoded.
4. **Inline hooks** (shell strings in the YAML, no `hooks/` directory) and **auto-env secrets** (merge the process environment with `.env`, inject by name or glob — secrets written to a tmpfile so they never appear in `docker run` process args).

## Install

```sh
just install   # builds a single-file escript and copies it to ~/bin/ginger
```

Requires Erlang/OTP on the machine. `just` available from [just.systems](https://just.systems).

You can also copy the generated `ginger` escript to any host that has Erlang installed — no other files needed.

## Commands

```sh
ginger deploy                   # build, push, and deploy with zero downtime
ginger deploy --skip-push       # deploy the registry image as-is (no build)
ginger deploy --tag v1          # pin the image tag; skip git-sha resolution
ginger redeploy                 # deploy without booting the proxy or pruning
ginger rollback <version>       # switch traffic back to a previous container
ginger remove                   # deregister from proxy and remove all containers
ginger status                   # show running version and proxy state per host
ginger lock release             # release a stuck deploy lock
ginger lock status              # show current lock holder
ginger config                   # print the parsed config (secrets redacted)
ginger version
ginger help
```

Global options:

| Flag | Default | Description |
|------|---------|-------------|
| `-c, --config <file>` | `ginger.yml` | Config file path |
| `-P, --skip-push` | false | Skip image build/push |
| `-t, --tag <version>` | git SHA | Pin the image tag |

## Configuration (`ginger.yml`)

```yaml
service: blog                   # container name prefix; must be [a-z0-9_-]+
image: ghcr.io/acme/blog        # image name without tag (tag = version)

servers:
  web:
    hosts: [10.0.0.1, 10.0.0.2, 10.0.0.3]
    primary: true               # barrier gatekeeper — other roles wait for this
  worker:
    hosts: [10.0.0.4]
    cmd: bundle exec sidekiq    # override the container CMD

registry:
  server: ghcr.io
  username: acme-ci
  password: GITHUB_TOKEN        # key name resolved from the secret map at deploy time

proxy:
  hosts: [blog.example.com]     # one or more virtual-host domains
  app_port: 3000
  ssl: true                     # kamal-proxy handles Let's Encrypt
  health_check_path: /up
  deploy_timeout: 30            # seconds kamal-proxy waits for health
  drain_timeout: 30

ssh:
  user: root                    # default: root

builder:
  arch: amd64
  remote: ssh://docker@builder  # omit to build locally with docker buildx

env:                            # plain env vars baked into every container
  RAILS_ENV: production

secrets:
  load: [.env]                  # dotenv files merged over the process env
  inject:                       # keys/globs forwarded as --env-file to docker run
    - RAILS_MASTER_KEY
    - "STRIPE_*"

rolling:
  limit: 25%                    # hosts per batch: integer or percentage
  wait: 5                       # seconds between batches
  parallel_roles: false         # true = non-primary roles boot concurrently

retain_containers: 5            # old containers kept after prune

# Explicit pipelines (optional — built-in defaults are used if omitted)
pipelines:
  deploy:
    - build
    - push
    - lock: acquire
    - hook: ./bin/check-db                        # local shell hook
    - boot-proxy
    - hook: { run: 'notify-slack deployed', local: true }
    - boot-app: { rolling: true }
    - prune
    - lock: release
    - hook: { run: 'echo done >> /var/log/deploys', local: false }
```

### Pipeline steps

| Step | Description |
|------|-------------|
| `build` | `docker buildx build --push` locally or on a remote builder over SSH |
| `push` | No-op when buildx already pushed; explicit for clarity |
| `boot-proxy` | Ensure a proxy is running; reuses an existing kamal-proxy if present |
| `boot-app` | Zero-downtime container swap; options: `rolling: bool`, `version: string` |
| `remove-app` | Deregister from proxy, stop and remove all service containers |
| `prune` | Remove old stopped containers and dangling images |
| `lock: acquire\|release\|status` | Mkdir-based deploy mutex on the primary host |
| `hook: <cmd>` | Inline shell; `local: true` = operator machine, `local: false` = each host |
| `healthcheck` | (reserved) |

### Secrets

ginger merges the process environment with each file in `secrets.load` (default `[.env]`). At deploy time it validates that every exact-name key in `secrets.inject` is present and non-empty, then writes the resolved values to a per-container tmpfile (`/tmp/.ginger-<service>-<role>-<version>.env`) and passes `--env-file` to `docker run` — secret values never appear in process args or `ps` output.

`registry.password` and any bare key name in the config resolve from the same merged map.

### Proxy reuse

ginger detects any running `kamal-proxy` container on the host and registers the new service against it, joining its Docker network automatically. A second proxy is only booted when none exists. Other apps registered with the shared proxy are never touched.

## Development

```sh
gleam run -- <command>        # run without installing
gleam test                    # run the test suite (73 tests)
gleam format src test         # format
just build                    # gleam build
just escript                  # gleam export escript → ./ginger (single-file binary)
just install                  # build escript and copy to ~/bin/ginger
```

## Example app

`learn/hana/` contains a Hono (Bun) example app with a `ginger.yml` configured
to deploy to a shared kamal-proxy host. See its README for details.
