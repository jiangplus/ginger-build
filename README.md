# ginger

Deploy containers anywhere, in Gleam. A [Kamal](https://kamal-deploy.org)-class
deployment tool: build an image, push it to a registry, and roll it out across
your servers over SSH with zero downtime via [kamal-proxy](https://github.com/basecamp/kamal-proxy).

Compared to Kamal, ginger makes four deliberate choices:

1. **kamal-proxy** for zero-downtime traffic switching — and reuses an already-running proxy on the host rather than booting a second one.
2. **Rolling updates** across multiple hosts and roles.
3. **Explicit actions in YAML** — deploy/redeploy/rollback/remove sequences are declared as named *pipelines* of built-in steps, not hardcoded.
4. **Inline hooks** (shell strings in the YAML, no `hooks/` directory) and **auto-env secrets** (merge the process environment with `.env`, inject by name or glob).

## Commands

```sh
ginger deploy                   # build, push, and deploy with zero downtime
ginger deploy --skip-push       # deploy the registry image as-is (no build)
ginger deploy --tag v1          # pin the image tag; skip git-sha resolution
ginger redeploy                 # deploy without booting the proxy or pruning
ginger rollback <version>       # switch traffic back to a previous container
ginger remove                   # deregister from proxy and remove all containers
ginger config                   # print the parsed config (redacted secrets)
ginger version                  # print ginger 0.1.1
ginger help
```

Global options available on all commands:

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
  password: GITHUB_TOKEN        # key name resolved from the secret map

proxy:
  host: blog.example.com
  app_port: 3000
  ssl: true                     # kamal-proxy handles Let's Encrypt
  health_check_path: /up
  deploy_timeout: 30            # seconds kamal-proxy waits for health
  drain_timeout: 30

ssh:
  user: root                    # default root

builder:
  arch: amd64
  remote: ssh://docker@builder  # omit to build locally with docker buildx

env:                            # plain env vars injected into every container
  RAILS_ENV: production

secrets:
  load: [.env]                  # dotenv files merged over the process env
  inject:                       # keys/globs to forward as container --env
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
| `build` | `docker buildx build --push` locally or on remote builder |
| `push` | No-op when buildx already pushed; explicit for clarity |
| `boot-proxy` | Ensure kamal-proxy is running; reuses existing one on the host |
| `boot-app` | Zero-downtime container swap per host; options: `rolling`, `version` |
| `remove-app` | Deregister from proxy, stop and remove all service containers |
| `prune` | Remove old stopped containers and dangling images |
| `lock: acquire\|release\|status` | Mkdir-based deploy mutex on primary host |
| `hook: <cmd>` | Inline shell; `local: true` runs on operator machine, `false` on each host |
| `healthcheck` | (reserved) |

### Secrets and auto-env

ginger merges the process environment with each file in `secrets.load` (default `[.env]`).
Keys listed under `secrets.inject` (exact names or `*`-globs) are forwarded to containers as `--env KEY=VALUE`.
`registry.password` and other `$NAME` references resolve from the same merged map — no separate secrets-file ceremony.

### Proxy reuse

When a host already runs a `kamal-proxy` container (e.g. shared across multiple apps), ginger detects it and registers the new service against it rather than booting a second proxy. The app container joins that proxy's Docker network automatically.

## Development

```sh
gleam run -- <command>        # run ginger
gleam test                    # run the test suite (67 tests)
gleam format src test         # format
```

## Build

```sh
gleam export erlang-shipment  # output: build/erlang-shipment/
./ginger <command>            # shell wrapper around the shipment
```

Requires Erlang/OTP on the target machine.

## Example app

`learn/hana/` contains a Hono (Bun) example app with `ginger.yml` configured
to deploy to a shared kamal-proxy host. See its README for details.
