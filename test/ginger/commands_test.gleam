import ginger/command
import ginger/commands/app
import ginger/commands/builder
import ginger/commands/lock
import ginger/commands/proxy
import ginger/commands/prune
import ginger/commands/registry
import ginger/config.{
  type Config, type Role, Builder, Config, Count, DockerRuntime,
  KamalProxyEgress, Proxy, Registry, Role, Rolling, Secrets,
}
import gleam/option.{None, Some}

fn test_config() -> Config {
  Config(
    service: "blog",
    image: "ghcr.io/acme/blog",
    servers: [Role(name: "web", hosts: ["10.0.0.1"], primary: True, cmd: None)],
    registry: Registry(
      server: "ghcr.io",
      username: "ci",
      password: "GITHUB_TOKEN",
    ),
    proxy: Some(Proxy(
      hosts: ["blog.example.com"],
      app_port: 3000,
      ssl: True,
      health_check_path: "/up",
      deploy_timeout: 30,
      drain_timeout: 30,
    )),
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
    secrets: Secrets(load: [".env"], inject: []),
    rolling: Rolling(limit: Count(1), wait: 0, parallel_roles: False),
    retain_containers: 5,
    ssh_user: "root",
    pipelines: [],
    runtime: DockerRuntime,
    egress: KamalProxyEgress,
    network: "ginger",
    traefik_provider: "docker",
    force_pull: False,
    volumes: [],
    extra_hosts: [],
    labels: [],
    resources: config.Resources(cpu: 256, memory: 512, memory_max: 0),
    ssh_timeout: 600,
    deps: [],
    nomad_job: None,
    deploy_only: False,
  )
}

fn web_role() -> Role {
  Role(name: "web", hosts: ["10.0.0.1"], primary: True, cmd: None)
}

pub fn registry_login_test() {
  let cmd = registry.login(test_config().registry, "secretpw")
  assert command.to_string(cmd) == "docker login ghcr.io -u 'ci' -p 'secretpw'"
}

pub fn builder_local_build_test() {
  let cmd = builder.build(test_config(), "abc1234")
  assert command.to_string(cmd)
    == "docker buildx build --push --platform linux/amd64 --provenance=false --sbom=false -t ghcr.io/acme/blog:abc1234 --cache-from type=registry,ref=ghcr.io/acme/blog:buildcache --cache-to type=registry,mode=min,ref=ghcr.io/acme/blog:buildcache ."
}

pub fn builder_remote_build_test() {
  let cfg =
    Config(
      ..test_config(),
      builder: Builder(
        arch: "arm64",
        remote: Some("ssh://docker@10.0.0.9"),
        context: ".",
        dockerfile: None,
        tags: [],
        cache: config.CacheMin,
        provenance: False,
        build_args: [],
        push_registry: None,
      ),
    )
  let cmd = builder.build(cfg, "abc1234")
  assert command.to_string(cmd)
    == "DOCKER_HOST=ssh://docker@10.0.0.9 docker buildx build --push --platform linux/arm64 --provenance=false --sbom=false -t ghcr.io/acme/blog:abc1234 --cache-from type=registry,ref=ghcr.io/acme/blog:buildcache --cache-to type=registry,mode=min,ref=ghcr.io/acme/blog:buildcache ."
}

pub fn builder_push_registry_test() {
  // push_registry swaps the host segment of `image` while preserving the repo
  // path, so build/push (and cache) target the mirror; the runtime image is
  // unchanged elsewhere.
  let cfg =
    Config(
      ..test_config(),
      image: "registry.juluo.xyz/blog",
      builder: Builder(
        arch: "amd64",
        remote: Some("ssh://ubuntu@wamo.city"),
        context: ".",
        dockerfile: None,
        tags: [],
        cache: config.CacheMin,
        provenance: False,
        build_args: [],
        push_registry: Some("mirror-registry.sola.day"),
      ),
    )
  assert builder.push_image(cfg) == "mirror-registry.sola.day/blog"
  let cmd = builder.build(cfg, "abc1234")
  assert command.to_string(cmd)
    == "DOCKER_HOST=ssh://ubuntu@wamo.city docker buildx build --push --platform linux/amd64 --provenance=false --sbom=false -t mirror-registry.sola.day/blog:abc1234 --cache-from type=registry,ref=mirror-registry.sola.day/blog:buildcache --cache-to type=registry,mode=min,ref=mirror-registry.sola.day/blog:buildcache ."
}

pub fn app_run_test() {
  let cmd =
    app.run(
      test_config(),
      web_role(),
      "10.0.0.1",
      "abc1234",
      [#("RAILS_ENV", "production")],
      "/tmp/.ginger-blog-web-abc1234.env",
      "ginger",
      [],
    )
  assert command.to_string(cmd)
    == "docker run --detach --restart unless-stopped --name blog-web-abc1234 --network ginger"
    <> " --env GINGER_CONTAINER_NAME='blog-web-abc1234' --env GINGER_VERSION='abc1234' --env GINGER_HOST='10.0.0.1'"
    <> " --env RAILS_ENV='production'"
    <> " --env-file /tmp/.ginger-blog-web-abc1234.env"
    <> " --label service='blog' --label role='web' --label version='abc1234'"
    <> " ghcr.io/acme/blog:abc1234"
}

pub fn app_run_with_cmd_test() {
  let worker =
    Role(
      name: "worker",
      hosts: ["10.0.0.4"],
      primary: False,
      cmd: Some("bundle exec sidekiq"),
    )
  let cmd =
    app.run(
      test_config(),
      worker,
      "10.0.0.4",
      "abc1234",
      [],
      "/tmp/ef",
      "kamal",
      [],
    )
  assert command.to_string(cmd)
    == "docker run --detach --restart unless-stopped --name blog-worker-abc1234 --network kamal"
    <> " --env GINGER_CONTAINER_NAME='blog-worker-abc1234' --env GINGER_VERSION='abc1234' --env GINGER_HOST='10.0.0.4'"
    <> " --env-file /tmp/ef"
    <> " --label service='blog' --label role='worker' --label version='abc1234'"
    <> " ghcr.io/acme/blog:abc1234 bundle exec sidekiq"
}

pub fn app_env_file_path_test() {
  assert app.env_file_path(test_config(), "web", "abc1234")
    == "/tmp/.ginger-blog-web-abc1234.env"
}

pub fn app_remove_test() {
  assert command.to_string(app.remove(test_config(), "web", "old123"))
    == "docker container rm blog-web-old123"
}

pub fn app_stop_and_rename_test() {
  assert command.to_string(app.stop(test_config(), "web", "old123"))
    == "docker container stop blog-web-old123"
  assert command.to_string(app.rename(
      test_config(),
      "web",
      "old123",
      "old123_replaced",
    ))
    == "docker rename blog-web-old123 blog-web-old123_replaced"
}

pub fn proxy_run_test() {
  assert command.to_string(proxy.run())
    == "docker run --name ginger-proxy --network ginger --detach --restart unless-stopped"
    <> " --publish 80:80 --publish 443:443 --volume ginger-proxy-config:/home/kamal-proxy/.config/kamal-proxy"
    <> " ghcr.io/basecamp/kamal-proxy:latest"
}

pub fn proxy_start_or_run_test() {
  assert command.to_string(proxy.start_or_run())
    == "docker container start ginger-proxy || docker run --name ginger-proxy --network ginger --detach --restart unless-stopped"
    <> " --publish 80:80 --publish 443:443 --volume ginger-proxy-config:/home/kamal-proxy/.config/kamal-proxy"
    <> " ghcr.io/basecamp/kamal-proxy:latest"
}

pub fn proxy_deploy_test() {
  let assert Some(p) = test_config().proxy
  // reuse an existing proxy named "kamal-proxy"
  let cmd = proxy.deploy(test_config(), web_role(), p, "abc1234", "kamal-proxy")
  assert command.to_string(cmd)
    == "docker exec kamal-proxy kamal-proxy deploy blog-web --target blog-web-abc1234:3000"
    <> " --host blog.example.com --tls --deploy-timeout 30s --drain-timeout 30s --health-check-path /up"
}

pub fn proxy_remove_test() {
  assert command.to_string(proxy.remove(
      test_config(),
      web_role(),
      "ginger-proxy",
    ))
    == "docker exec ginger-proxy kamal-proxy remove blog-web"
}

pub fn proxy_detect_test() {
  assert command.to_string(proxy.detect())
    == "docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /kamal-proxy/ {print $1; exit}'"
}

pub fn lock_acquire_release_test() {
  assert command.to_string(lock.acquire(test_config()))
    == "mkdir .ginger/lock-blog"
  assert command.to_string(lock.release(test_config()))
    == "rm -r .ginger/lock-blog"
}

pub fn prune_all_test() {
  assert command.to_string(prune.all(test_config()))
    == "docker container prune --force --filter label=service=blog"
    <> " && docker image prune --force --filter label=service=blog"
}

pub fn builder_context_and_dockerfile_test() {
  // dockerfile is declared relative to the context; docker resolves -f
  // against cwd, so the rendered command must join them.
  let cfg =
    Config(
      ..test_config(),
      builder: Builder(
        arch: "amd64",
        remote: None,
        context: "../repo",
        dockerfile: "cmd/relay/Dockerfile" |> Some,
        tags: ["latest"],
        cache: config.CacheNone,
        provenance: False,
        build_args: [],
        push_registry: None,
      ),
    )
  let cmd = builder.build(cfg, "abc1234")
  assert command.to_string(cmd)
    == "docker buildx build --push --platform linux/amd64 --provenance=false --sbom=false -t ghcr.io/acme/blog:abc1234 -t ghcr.io/acme/blog:latest -f ../repo/cmd/relay/Dockerfile ../repo"
}
