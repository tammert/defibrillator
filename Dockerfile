# syntax=docker/dockerfile:1

# ---- build: static Go binary, no CGO ----
FROM golang:1.24 AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o /defibrillator .

# ---- runtime ----
# A FROM scratch base can't do the SSH half: idle poweroff shells out to
# `ssh <target> 'systemctl poweroff'`. Add a minimal shell + OpenSSH client.
FROM alpine:3.20
RUN apk add --no-cache ca-certificates openssh-client
# 102-byte WOL magic packets are UDP to :9 — no extra libs needed.
# ssh reads the key from the bind-mounted /root/.ssh (compose).
COPY --from=build /defibrillator /defibrillator
# 65534 = nobody; the /root/.ssh mount is 700 root-owned, so run as root
# inside the container (host network + WOL broadcast are root-adjacent anyway).
USER root
ENTRYPOINT ["/defibrillator"]
