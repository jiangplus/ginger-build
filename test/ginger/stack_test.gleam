import ginger/config.{
  Builder, Config, Count, NomadRuntime, Registry, Role, Rolling, Secrets,
  TraefikEgress,
}
import ginger/stack
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
