default:
    just --list

build:
    gleam build

test:
    gleam test

format:
    gleam format src test

check:
    gleam format --check src test

shipment:
    gleam export erlang-shipment

escript:
    gleam export escript

install: escript
    mkdir -p $HOME/bin
    cp ginger $HOME/bin/ginger
    echo "Installed: $($HOME/bin/ginger version)"
