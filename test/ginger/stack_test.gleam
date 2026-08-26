import ginger/config.{
  Builder, Config, Count, NomadRuntime, Registry, Role, Rolling, Secrets,
  TraefikEgress,
}
import ginger/stack
import gleam/erlang/process
import gleam/list
import gleam/option.{None}

fn cfg(service: String, deps: List(String)) -> config.Config {
  Config(
    service: service,
    image: "reg.example.com/" <> service,
    servers: [Role(name: "web", hosts: ["10.0.0.1"], primary: True, cmd: None)],
    registry: Registry(server: "reg.example.com", username: "u", password: "P"),
    proxy: None,
    builder: Builder(
      arch: "amd64",
      remote: None,
      context: ".",
      dockerfile: None,
      tags: [],
      cache: config.CacheMin,
      provenance: False,
      build_args: [],
      push_registry: None,
    ),
    env: [],
    secrets: Secrets(load: [], inject: []),
    rolling: Rolling(limit: Count(1), wait: 0, parallel_roles: False),
    retain_containers: 5,
    ssh_user: "root",
    pipelines: [],
    runtime: NomadRuntime,
    egress: TraefikEgress,
    network: "ginger",
    traefik_provider: "docker",
    force_pull: False,
    volumes: [],
    extra_hosts: [],
    labels: [],
    resources: config.Resources(cpu: 256, memory: 512, memory_max: 0),
    ssh_timeout: 600,
    deps: deps,
    nomad_job: None,
    deploy_only: False,
    local_image: False,
    tag: None,
  )
}

pub fn normalize_test() {
  assert stack.normalize("a/b/../c/./d.yml") == "a/c/d.yml"
  assert stack.normalize("/x//y/z.yml") == "/x/y/z.yml"
  assert stack.normalize("./a.yml") == "a.yml"
}

pub fn resolve_dep_test() {
  assert stack.resolve_dep("deploy/web.yml", "db.yml") == "deploy/db.yml"
  assert stack.resolve_dep("deploy/web.yml", "../infra/db.yml")
    == "infra/db.yml"
  assert stack.resolve_dep("web.yml", "/abs/db.yml") == "/abs/db.yml"
}

pub fn topo_order_test() {
  // ouranos depends on pds; pds depends on plc; plc on nothing.
  let entries = [
    stack.Entry(path: "d/ouranos.yml", config: cfg("ouranos", ["pds.yml"])),
    stack.Entry(path: "d/pds.yml", config: cfg("pds", ["plc.yml"])),
    stack.Entry(path: "d/plc.yml", config: cfg("plc", [])),
  ]
  let assert Ok(ordered) = stack.topo_order(entries)
  assert list.map(ordered, fn(e) { e.config.service })
    == ["plc", "pds", "ouranos"]
}

pub fn topo_order_ignores_outside_deps_test() {
  // dep on a config that isn't part of the deploy set → ignored.
  let entries = [
    stack.Entry(path: "a.yml", config: cfg("a", ["not-in-set.yml"])),
    stack.Entry(path: "b.yml", config: cfg("b", ["a.yml"])),
  ]
  let assert Ok(ordered) = stack.topo_order(entries)
  assert list.map(ordered, fn(e) { e.config.service }) == ["a", "b"]
}

pub fn topo_order_cycle_test() {
  let entries = [
    stack.Entry(path: "a.yml", config: cfg("a", ["b.yml"])),
    stack.Entry(path: "b.yml", config: cfg("b", ["a.yml"])),
  ]
  let assert Error(_) = stack.topo_order(entries)
}

/// Group mode used to build every service in the set, `deploy_only` ones
/// included — `docker buildx build` in a directory with no Dockerfile, which
/// fails the whole deploy. Single-config deploys had always honoured the flag.
pub fn split_pipeline_skips_build_for_deploy_only_test() {
  let base = cfg("plc", [])
  let assert Ok(#(has_build, rest)) =
    stack.split_pipeline(Config(..base, deploy_only: True), "deploy")
  assert has_build == False
  assert !list.contains(rest.steps, config.Build)
  assert !list.contains(rest.steps, config.Push)
}

pub fn split_pipeline_skips_build_for_local_image_test() {
  let base = cfg("yatch", [])
  let assert Ok(#(has_build, _)) =
    stack.split_pipeline(Config(..base, local_image: True), "deploy")
  assert has_build == False
}

/// A service with source still builds — the fix must not disable builds wholesale.
pub fn split_pipeline_keeps_build_for_source_service_test() {
  let assert Ok(#(has_build, _)) =
    stack.split_pipeline(cfg("rice", []), "deploy")
  assert has_build == True
}

/// The build pool must keep `concurrency` builds in flight, starting the next
/// one the moment a slot frees.
///
/// With fixed batches (the old behaviour) a batch had to finish entirely
/// before the next began: here A would free its slot after 10ms but C could
/// not start until B's 300ms were up, so C finished last. With a rolling pool
/// C starts right after A and finishes long before B.
pub fn run_group_starts_next_build_as_soon_as_a_slot_frees_test() {
  let events = process.new_subject()
  let job = fn(name, sleep_ms) {
    stack.Job(
      entry: stack.Entry(path: name <> ".yml", config: cfg(name, [])),
      build: option.Some(fn() {
        process.sleep(sleep_ms)
        process.send(events, name)
        Ok(Nil)
      }),
      deploy: fn() { Ok(Nil) },
    )
  }
  let assert Ok(_) =
    stack.run_group([job("a", 10), job("b", 300), job("c", 10)], 2, fn(_) {
      Nil
    })
  let assert Ok(first) = process.receive(events, 2000)
  let assert Ok(second) = process.receive(events, 2000)
  let assert Ok(third) = process.receive(events, 2000)
  assert [first, second, third] == ["a", "c", "b"]
}
