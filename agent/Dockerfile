# syntax=docker/dockerfile:1
# The build stage runs on the builder's own platform and cross-compiles for
# the target, so a multi-platform build never runs Go under emulation.
FROM --platform=$BUILDPLATFORM golang:1.27 AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
ARG VERSION=dev
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -trimpath \
      -ldflags "-s -w -X main.version=${VERSION}" \
      -o /out/meridian-agent .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/meridian-agent /meridian-agent
ENTRYPOINT ["/meridian-agent"]
