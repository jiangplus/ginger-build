---
name: ginger
description: >
  Set up and use ginger — a Gleam/BEAM container deployment tool similar to Kamal.
  Use this skill whenever the user wants to: install ginger, create a ginger.yml,
  deploy a containerised app with ginger, configure the proxy or secrets, roll back
  a deployment, or troubleshoot a ginger deploy failure. Also trigger when the user
  mentions "ginger deploy", "ginger.yml", or asks how to get ginger running on a
  new server or project.
---

# ginger deployment skill

ginger is a single-binary deployment tool (Gleam/OTP escript) that builds a Docker
image, pushes it to a registry, and rolls it out over SSH with zero downtime via
kamal-proxy. Think Kamal, but written in Gleam.

Release page: https://github.com/jiangplus/ginger-build/releases

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
ginger version   # should print: ginger 0.1.6
```

Make sure `~/.local/bin` is on your PATH (add to `~/.bashrc` / `~/.zshrc` / `config.fish`
if needed).

---

## Step 3 — Create `ginger.yml`

Run this in the project root. Ask the user for their values and fill in the template:

```yaml
service: myapp                        # container name prefix [a-z0-9_-]
image: ghcr.io/myorg/myapp            # image name (tag = version, auto-set to git SHA)

servers:
  web:
    hosts: [10.0.0.1]                 # SSH-accessible server IPs or hostnames
    primary: true

registry:
  server: ghcr.io                     # or docker.io, registry.example.com
  username: myorg
  password: GITHUB_TOKEN              # name of the env var / .env key holding the password

proxy:
  hosts: [myapp.example.com]          # domain(s) kamal-proxy will route to this service
  app_port: 3000                      # port the container listens on
  ssl: true                           # kamal-proxy handles Let's Encrypt automatically
  health_check_path: /up

ssh:
  user: root                          # default: root

env:                                  # plain (non-secret) container env vars
  NODE_ENV: production

secrets:
  load: [.env]                        # dotenv files to merge with process env
  inject:                             # keys forwarded to the container via --env-file
    - GITHUB_TOKEN
    - "DATABASE_*"
```

**Key questions to ask the user before filling this in:**
- What's the service name and Docker image path?
- What registry do they use (ghcr.io / Docker Hub / self-hosted)?
- What are the server IPs and SSH user?
- What domain should the app be reachable at?
- What port does the container listen on?
- What secrets need to be injected (API keys, DB passwords)?

---

## Step 4 — Set up secrets

ginger reads secrets from the process environment and `.env` files — never from the
YAML directly. Before deploying:

```sh
# .env (gitignored)
GITHUB_TOKEN=ghp_xxxxxxxxxxxx
DATABASE_URL=postgres://...
```

Or export them in the shell:
```sh
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
```

Check that all required keys are present — `ginger deploy` will validate this before
doing anything:
```sh
ginger config          # prints parsed config with secrets redacted
```

---

## Step 5 — First deploy

```sh
ginger deploy
```

This runs the default pipeline: build image → push to registry → acquire lock →
boot proxy (or reuse existing kamal-proxy) → zero-downtime container swap → prune
old containers → release lock.

**Useful flags:**
```sh
ginger deploy --skip-push          # skip build; deploy whatever is in the registry
ginger deploy --tag v1.2.3         # pin a specific image tag instead of git SHA
ginger redeploy                    # deploy without touching the proxy or pruning
ginger rollback <version>          # switch traffic back to an older container
ginger status                      # show running version and proxy state per host
ginger remove                      # deregister from proxy and delete all containers
```

---

## Troubleshooting

**"secrets.inject keys not set"** — a key listed under `secrets.inject` is missing or
empty. Export it or add it to `.env`.

**"SSH error: connect … timeout"** — the server is unreachable or the SSH user/key is
wrong. Test with `ssh <user>@<host>` directly.

**"deploy lock already held"** — a previous deploy crashed while holding the lock.
Release it: `ginger lock release`.

**Build output streams to the terminal** — this is intentional; `docker buildx` progress
appears live so you can see layer caching hits and push progress in real time.

**kamal-proxy already running** — ginger detects and reuses any existing kamal-proxy on
the host, so other apps served by that proxy are never disrupted.

---

## Common ginger.yml patterns

**Multiple servers (rolling update):**
```yaml
servers:
  web:
    hosts: [10.0.0.1, 10.0.0.2, 10.0.0.3]
    primary: true
rolling:
  limit: 1        # one host at a time
  wait: 5         # seconds between batches
```

**Background worker role (no proxy):**
```yaml
servers:
  web:
    hosts: [10.0.0.1]
    primary: true
  worker:
    hosts: [10.0.0.2]
    cmd: bundle exec sidekiq
```

**Multiple domains on one service:**
```yaml
proxy:
  hosts: [myapp.com, www.myapp.com]
  app_port: 3000
  ssl: true
```

**Remote builder (build on a dedicated Docker host):**
```yaml
builder:
  arch: amd64
  remote: ssh://docker@builder.example.com
```

**Custom deploy pipeline:**
```yaml
pipelines:
  deploy:
    - build
    - push
    - lock: acquire
    - hook: ./bin/check-migrations     # runs locally before deploy
    - boot-proxy
    - boot-app: { rolling: true }
    - prune
    - lock: release
```
