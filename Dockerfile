# Runner image for CI: Erlang/OTP + the ginger CLI, ready to `ginger deploy`.
# Built from the official erlang image so the OTP version always matches what
# ginger requires (27+); the ginger binary itself is pulled from the latest
# GitHub release rather than built here, so this stays a one-layer download.
FROM erlang:27-alpine

RUN apk add --no-cache curl openssh-client docker-cli git

RUN curl -fsSL https://github.com/jiangplus/ginger-build/releases/latest/download/ginger \
      -o /usr/local/bin/ginger \
    && chmod +x /usr/local/bin/ginger

WORKDIR /workspace
ENTRYPOINT ["ginger"]
CMD ["--help"]
