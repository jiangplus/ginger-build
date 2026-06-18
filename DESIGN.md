# ginger — Design Notes & Open Improvements

This document records design decisions and known weaknesses in ginger,
prioritised. Each item states the problem, the evidence, and a concrete
direction. These came out of bringing the Nomad + Traefik path up end-to-end.

The four shipped bug fixes referenced below (labels shape, missing env,
registry auth, single Traefik service) are described in the commit that added
the Nomad + Traefik runner/egress.

---

## 1. Build the Nomad job spec with a real JSON encoder, not string concatenation

**Problem.** `commands/nomad.gleam` builds the Nomad job spec by concatenating
strings (`job_json`, `json_map`, `json_escape`). There is no type between the
Gleam code and the JSON that Nomad parses, so any structural mistake surfaces
only at runtime as a Nomad validation error.

**Evidence.** Three of the four bugs found while bringing the Nomad path up were
direct consequences of hand-rolled JSON:

- `labels` was emitted as a JSON object `{...}` but the Docker driver requires a
  list-of-map `[{...}]` (`Inappropriate value for attribute "labels"`).
- Injected secrets were never serialised into the `Env` map — a missing-field
  bug that string concatenation cannot catch.
- The registry `auth` block was appended as a hand-written `,"auth":{...}`
  fragment.

**Direction.** Introduce typed records for the job spec and encode with
`gleam_json`:

```gleam
pub type NomadJob {
  NomadJob(id: String, task_groups: List(TaskGroup))
}
pub type DockerConfig {
  DockerConfig(
    image: String,
    ports: List(String),
    network_mode: String,
    labels: List(Dict(String, String)),   // shape is in the type
    auth: Option(RegistryAuth),
  )
}
```

The driver's contract (`labels` is a list, `ports` is a list, `auth` is an
object) then lives in the types and is checked at compile time. `json_escape`
and `json_map` go away. This is the highest-value change: it removes the entire
class of bug that dominated bring-up.

---

## 2. Gate the Nomad deploy on health, like the Docker/kamal-proxy path

**Problem.** `boot_host_nomad` submits the job and returns. It does not wait for
the Nomad deployment to become healthy, so ginger's success/failure does not
reflect the application's actual state.

**Evidence.**

- Failed allocations accumulated across retries (4–5 `failed` allocs per
  attempt) and ginger never noticed; the operator had to
  `nomad job stop -purge` by hand before each resubmit.
- `nomad job run`'s exit code and the real deployment status diverged — a deploy
  could exit `0` while the container was crash-looping.
- `proxy.deploy_timeout` / `drain_timeout` are documented as "kamal-proxy only",
  yet Nomad has its own progress deadline that ginger reads nowhere. The two
  runners have inconsistent health semantics.

**Direction.** After `nomad job run`, poll `nomad deployment status` (or
`nomad job deployments -json`) until it reaches `successful` or `failed`, bounded
by a timeout, and map that to ginger's exit status. This makes the Nomad path's
health gating equivalent to the kamal-proxy path's health-checked cutover, and
lets `deploy_timeout` apply to both runners. Stop/purge a prior failed job
version as part of resubmission so retries do not pile up dead allocations.

---

## 6. Secrets land in Nomad job state — the Docker path's protection is lost

**Problem.** The Docker runner deliberately writes secrets to a per-deploy
env-file passed via `--env-file`, so secret values never appear in process args
or `ps` output. The Nomad runner embeds the full env — including injected
secrets and the resolved registry password — directly in the job JSON.

**Evidence.** `container_env(context)` (plain + secrets) and the registry
`auth` block are serialised into the job spec submitted via `nomad job run`.
That JSON is persisted in Nomad's server state and is readable through the Nomad
API / `nomad job inspect`. The carefully-avoided plaintext exposure on the
Docker path returns on the Nomad path.

**Direction.** At minimum, document the trade-off explicitly so operators know
secrets are visible to anyone with Nomad API access. Better, use Nomad's native
secret handling: store values as Nomad Variables (or in Vault) and reference
them from a `template` stanza that renders the container env at allocation time,
keeping plaintext out of the job spec and out of `job inspect`. The registry
credential should follow the same path rather than being inlined as `auth`.

---

## 7. `network_mode: "ginger"` is hard-coded and implicitly provisioned

**Problem.** The Nomad job hard-codes `network_mode: "ginger"`. That Docker
network is created as a side effect of booting ginger's own Traefik container,
so the runner depends on a resource it does not itself guarantee, under a name
that cannot be configured.

**Evidence.** With an external/host-managed Traefik (no `ginger-traefik`
container booted), the `ginger` network is not created by ginger; bring-up
required confirming the network existed and creating it manually. The name is
also fixed in code, so a host already using `ginger` for something else, or an
operator who wants a different topology, has no escape hatch.

**Direction.** Make the network name configurable (e.g. `proxy.network` /
`runner.network`, defaulting to `ginger`), and ensure it exists at deploy time
with an idempotent `docker network create` (ignore "already exists"). Decoupling
network provisioning from "ginger booted its own Traefik" lets the Nomad +
external-proxy topology work without manual setup. (Relates to making proxy
management a first-class config concern.)

---

## 8. Snapshot-test the generated job spec

**Problem.** The suite has 76 passing tests, none of which inspect the structure
of the Nomad job spec. The labels-as-object bug shipped green.

**Direction.** Add a test that generates the job spec, parses it back as JSON,
and asserts on structure rather than on a literal string:

- `Config.Task[0].Config.labels` is an array whose single element contains the
  expected `traefik.*` keys;
- `Env` contains every injected secret key;
- `auth` is present (and an object) when a registry password resolves;
- both the `web` and `websecure` routers reference the same Traefik service.

Parsing-and-asserting (rather than golden-string matching) keeps the test
robust to key ordering and whitespace. Combined with the typed encoder from #1,
this closes the regression gap that allowed three of the four bring-up bugs.

---

## Priority

If only a subset is done, **#1 (typed JSON)** plus **#2 (health gating)** remove
the bulk of the Nomad-path fragility. **#8** locks the gains in place. **#6** and
**#7** harden the path for real multi-tenant / external-proxy operation.
