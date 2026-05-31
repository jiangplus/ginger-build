# ginger

A Gleam CLI tool that connects to a remote server via SSH and lists files in the home directory.

## Usage

```sh
./ginger <host> [user]
```

```sh
./ginger <hostname>          # defaults to root
./ginger <hostname> <home>
```

## Build

```sh
gleam export erlang-shipment
```

Then run the program:

```sh
./ginger
```

Requires Erlang on the target machine. The shipment is output to `build/erlang-shipment/`.

## Development

```sh
gleam run -- <host> [user]   # Run the project
gleam test                    # Run the tests
```
