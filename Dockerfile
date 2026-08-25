# Runner image for CI: Erlang/OTP + the ginger CLI, ready to `ginger deploy`.
# Built from the official erlang image so the OTP version always matches what
# ginger requires; the ginger binary itself is pulled from the latest GitHub
# release rather than built here, so this stays a one-layer download.
#
# Pin to whatever OTP release actually builds the published ginger escript,
# not just "27+" — the release's .beam files failed to load ("corrupt atom
# table") under erlang:27-alpine even though 27 nominally satisfies the
# skill's minimum, because the binary was built with a newer OTP.
FROM erlang:29-alpine

RUN apk add --no-cache curl openssh-client docker-cli git

RUN curl -fsSL https://github.com/jiangplus/ginger-build/releases/latest/download/ginger \
      -o /usr/local/bin/ginger \
    && chmod +x /usr/local/bin/ginger

WORKDIR /workspace
ENTRYPOINT ["ginger"]
CMD ["--help"]
