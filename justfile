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

install: shipment
    cp -r build/erlang-shipment $HOME/.local/share/ginger
    mkdir -p $HOME/bin
    printf '#!/bin/sh\nexec "$HOME/.local/share/ginger/entrypoint.sh" run "$@"\n' > $HOME/bin/ginger
    chmod +x $HOME/bin/ginger
    echo "Installed: $($HOME/bin/ginger version)"
