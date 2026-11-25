# syntax=docker/dockerfile:1
FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
      -ldflags "-s -w -X main.version=${VERSION}" \
      -o /out/meridian-agent .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/meridian-agent /meridian-agent
USER nonroot:nonroot
ENTRYPOINT ["/meridian-agent"]
