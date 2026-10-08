# syntax=docker/dockerfile:1

# ---- build: static Go binary, no CGO ----
FROM golang:1.24 AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o /defibrillator .

# ---- runtime: static binary on scratch, no shell, ~2 MB ----
FROM scratch
COPY --from=build /defibrillator /defibrillator
# 102-byte WOL magic packets need UDP egress to :9 - nothing to install
USER 65534:65534
ENTRYPOINT ["/defibrillator"]
