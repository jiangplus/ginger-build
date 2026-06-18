# ginger

Deploy containers anywhere, in Gleam. A [Kamal](https://kamal-deploy.org)-class
deployment tool: build an image, push it to a registry, and roll it out across
your servers over SSH with zero downtime. Traffic routing is handled by
[Traefik](https://traefik.io) (default) or [kamal-proxy](https://github.com/basecamp/kamal-proxy);
container scheduling by [Nomad](https://www.nomadproject.io) (default) or plain Docker.

Compared to Kamal, ginger makes four deliberate choices:

1. **Pluggable runner and egress** — default stack is Nomad + Traefik; switch to Docker + kamal-proxy with two lines in `ginger.yml`. Only these two combinations are supported.
2. **Rolling updates** across multiple hosts and roles.
3. **Explicit actions in YAML** — deploy/redeploy/rollback/remove sequences are declared as named *pipelines* of built-in steps, not hardcoded.
4. **Inline hooks** (shell strings in the YAML, no `hooks/` directory) and **auto-env secrets** (merge the process environment with `.env`, inject by name or glob — secrets written to a tmpfile so they never appear in process args).

## Install

### Step 1 — Install Erlang/OTP

ginger ships as a single-file escript. The only runtime dependency is **Erlang/OTP 27 or later**. The system `erlang` package on Ubuntu/Debian is often OTP 24 or older — use the Erlang Solutions repo instead.

**macOS**

```sh
brew install erlang        # installs OTP 27+
```

**Ubuntu / Debian**

The system `apt` package is too old. Use the Erlang Solutions repo:

```sh
wget -qO- https://packages.erlang-solutions.com/ubuntu/erlang_solutions.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/erlang-solutions.gpg
echo "deb [signed-by=/usr/share/keyrings/erlang-solutions.gpg] \
  https://packages.erlang-solutions.com/ubuntu $(lsb_release -cs) contrib" \
  | sudo tee /etc/apt/sources.list.d/erlang-solutions.list
sudo apt update && sudo apt install -y esl-erlang
```

**Windows**

Download the OTP 27+ `.exe` installer from [erlang.org/downloads](https://www.erlang.org/downloads). ginger requires WSL2 (Ubuntu) for SSH — install Erlang inside WSL2 using the Ubuntu steps above and run ginger from there.

Verify on any platform:

```sh
erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell
# must print "27", "28", or "29"
```

### Step 2 — Install ginger

Download the latest `ginger` escript from [Releases](https://github.com/jiangplus/ginger-build/releases) and put it on your PATH:

```sh
curl -fsSL https://github.com/jiangplus/ginger-build/releases/latest/download/ginger \
  -o ~/.local/bin/ginger
chmod +x ~/.local/bin/ginger
ginger version
```

Or build from source (requires [Gleam](https://gleam.run/getting-started/installing/) and [just](https://just.systems)):

```sh
git clone https://github.com/jiangplus/ginger.git
cd ginger
just install   # builds escript and copies it to ~/bin/ginger
```

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

runner: nomad                   # nomad (default) | docker
egress: traefik                 # traefik (default) | kamal-proxy
                                # valid combinations: nomad+traefik, docker+kamal-proxy

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
  hosts: [blog.example.com, www.example.com]  # one or more virtual-host domains
  app_port: 3000
  ssl: true                     # TLS via Let's Encrypt (handled by Traefik or kamal-proxy)
  health_check_path: /up
  deploy_timeout: 30            # seconds the proxy waits for health (kamal-proxy only)
  drain_timeout: 30             # seconds to drain connections before cutover (kamal-proxy only)

ssh:
  user: root                    # default: root

builder:
  arch: amd64
  remote: ssh://docker@builder  # omit to build locally with docker buildx

env:                            # plain env vars baked into every container
  RAILS_ENV: production

secrets:
  load: [.env]                  # dotenv files merged over the process env
  inject:                       # keys/globs forwarded to the container as env vars
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

### Runner and egress backends

ginger supports two deployment stacks selected by the `runner` and `egress` fields.
Only these combinations are valid — mixing them is a config error.

| `runner` | `egress` | Container scheduling | Traffic routing |
|----------|----------|----------------------|-----------------|
| `nomad` (default) | `traefik` (default) | Nomad job via `nomad job run` | Traefik Docker provider (label-based auto-discovery) |
| `docker` | `kamal-proxy` | `docker run` over SSH | kamal-proxy (explicit register/deregister) |

**Nomad + Traefik** (default): ginger submits a Nomad job spec containing the Docker
image and Traefik routing labels. Nomad schedules and manages the container; Traefik
detects it automatically via the Docker provider and begins routing traffic. Nomad
handles rolling updates and restarts internally — ginger does not explicitly stop the
old container.

**Docker + kamal-proxy**: ginger SSHes to each host, runs `docker run` directly,
then calls `kamal-proxy deploy` to perform a health-gated traffic switch, and finally
stops and removes the old container.

### Pipeline steps

| Step | Description |
|------|-------------|
| `build` | `docker buildx build --push` locally or on a remote builder over SSH; output streams live |
| `push` | No-op when buildx already pushed; explicit for clarity |
| `boot-proxy` | Ensure the egress proxy is running; reuses an existing Traefik or kamal-proxy if present |
| `boot-app` | Deploy containers: Nomad job submit (nomad) or zero-downtime Docker swap (docker) |
| `remove-app` | Stop and remove all service containers; deregister from proxy if using kamal-proxy |
| `prune` | Docker: remove old stopped containers and dangling images. Nomad: `nomad system gc` |
| `lock: acquire\|release\|status` | Mkdir-based deploy mutex on the primary host |
| `hook: <cmd>` | Inline shell; `local: true` = operator machine, `local: false` = each host |
| `healthcheck` | (reserved) |

### Secrets

ginger merges the process environment with each file in `secrets.load` (default `[.env]`). At deploy time it validates that every exact-name key in `secrets.inject` is present and non-empty.

- **Docker runner**: resolved values are written to a per-container tmpfile and passed as `--env-file` to `docker run` — secret values never appear in process args or `ps` output.
- **Nomad runner**: env vars are embedded in the Nomad job spec's `Env` map, which Nomad passes to the container at allocation time.

`registry.password` and any bare key name in the config resolve from the same merged map.

### Egress proxy reuse

On each deploy ginger checks for a running Traefik or kamal-proxy container before
booting a new one:

- **Traefik**: any container whose image tag contains `traefik` is reused. The new
  container's labels are picked up automatically.
- **kamal-proxy**: any container whose image tag contains `kamal-proxy` is reused.
  ginger joins its Docker network and registers against it. Other apps registered with
  the shared proxy are never touched.

### Multi-domain routing

`proxy.hosts` accepts a list of domain names. Each domain is routed to the same service:

```yaml
proxy:
  hosts: [blog.example.com, www.example.com]
  app_port: 3000
```

The scalar shorthand still works for a single domain:

```yaml
proxy:
  host: blog.example.com
  app_port: 3000
```

## Development

```sh
gleam run -- <command>        # run without installing
gleam test                    # run the test suite (76 tests)
gleam format src test         # format
just build                    # gleam build
just escript                  # gleam export escript → ./ginger (single-file binary)
just install                  # build escript and copy to ~/bin/ginger
```

## Example app

`learn/hana/` contains a Hono (Bun) example app with a `ginger.yml` configured
to deploy to a shared kamal-proxy host. See its README for details.
