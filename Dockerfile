# Runner image for CI: Erlang/OTP + the ginger CLI, ready to `ginger deploy`.
#
# The GitHub release asset ("latest") is stuck at v0.1.6 — far behind the
# repo's actual version (see gleam.toml) — so it is NOT a reliable source.
# Use the escript checked into the repo root instead, which tracks HEAD.
#
# erlang:29-alpine, not just "27+": the checked-in escript's .beam files
# failed to load under 27-alpine ("corrupt atom table") because they were
# built with a newer OTP than the CLI's stated minimum.
FROM erlang:29-alpine

RUN apk add --no-cache openssh-client docker-cli docker-cli-buildx git

COPY ginger /usr/local/bin/ginger
RUN chmod +x /usr/local/bin/ginger

WORKDIR /workspace
ENTRYPOINT ["ginger"]
CMD ["--help"]
