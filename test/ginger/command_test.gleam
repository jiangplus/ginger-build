import ginger/command

pub fn run_joins_tokens_test() {
  let cmd = command.run(["mkdir", "-p", "/tmp/x"])
  assert command.to_string(cmd) == "mkdir -p /tmp/x"
}

pub fn docker_prefixes_test() {
  let cmd = command.docker(["ps", "--all"])
  assert command.to_string(cmd) == "docker ps --all"
}

pub fn empty_tokens_dropped_test() {
  let cmd = command.run(["docker", "run", "", "--detach", ""])
  assert command.to_string(cmd) == "docker run --detach"
}

pub fn and_combinator_test() {
  let cmd =
    command.and([command.run(["a"]), command.run(["b"]), command.run(["c"])])
  assert command.to_string(cmd) == "a && b && c"
}

pub fn or_combinator_test() {
  let cmd =
    command.or([
      command.docker(["container", "start", "proxy"]),
      command.docker(["run", "proxy"]),
    ])
  assert command.to_string(cmd)
    == "docker container start proxy || docker run proxy"
}

pub fn pipe_combinator_test() {
  let cmd =
    command.pipe([
      command.docker(["ps", "--quiet"]),
      command.run(["head", "-1"]),
    ])
  assert command.to_string(cmd) == "docker ps --quiet | head -1"
}

pub fn chain_combinator_test() {
  let cmd = command.chain([command.run(["cd", "/app"]), command.run(["ls"])])
  assert command.to_string(cmd) == "cd /app ; ls"
}

pub fn quote_wraps_in_single_quotes_test() {
  assert command.quote("hello world") == "'hello world'"
}

pub fn quote_escapes_embedded_single_quote_test() {
  assert command.quote("it's") == "'it'\\''s'"
}

pub fn flag_pairs_builds_env_args_test() {
  let tokens =
    command.flag_pairs("--env", [
      #("RAILS_ENV", "production"),
      #("PORT", "3000"),
    ])
  assert tokens == ["--env", "RAILS_ENV='production'", "--env", "PORT='3000'"]
}
