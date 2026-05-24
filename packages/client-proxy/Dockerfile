ARG JFROG_DOCKER_REGISTRY=artifactory.aic.aws.zoomdev.us/zoom-docker-virtual
FROM golang:1.24-alpine3.20 AS builder

ARG JFROG_ARTIFACTORY_URL=https://artifactory.aic.aws.zoomdev.us/artifactory
ENV GOPROXY=https://proxy.golang.org,direct

RUN apk add --no-cache make

WORKDIR /build/shared

COPY .shared/go.mod .shared/go.sum ./
RUN go mod download

COPY .shared/pkg pkg

WORKDIR /build/proxy

COPY go.mod go.sum Makefile ./
RUN go mod download

COPY internal/ ./internal/
COPY main.go main.go

ARG COMMIT_SHA
RUN --mount=type=cache,target=/root/.cache/go-build make build COMMIT_SHA=${COMMIT_SHA}
RUN chmod +x /build/proxy/bin/client-proxy

FROM alpine:3.17

COPY --from=builder /build/proxy/bin/client-proxy .

ENTRYPOINT [ "./client-proxy"]
