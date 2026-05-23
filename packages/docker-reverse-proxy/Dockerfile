ARG JFROG_DOCKER_REGISTRY=artifactory.aic.aws.zoomdev.us/zoom-docker-virtual
FROM ${JFROG_DOCKER_REGISTRY}/golang:1.24-alpine3.20 AS builder

ARG JFROG_ARTIFACTORY_URL=https://artifactory.aic.aws.zoomdev.us/artifactory
ENV GOPROXY=${JFROG_ARTIFACTORY_URL}/api/go/zoom-go-virtual

RUN apk add --no-cache make

WORKDIR /build/shared

COPY .shared/go.mod .shared/go.sum ./
RUN go mod download

COPY .shared/pkg pkg

WORKDIR /build/docker-reverse-proxy

COPY go.mod go.sum Makefile ./
RUN go mod download

COPY main.go main.go
COPY internal internal

ARG COMMIT_SHA
RUN --mount=type=cache,target=/root/.cache/go-build make build COMMIT_SHA=${COMMIT_SHA}

RUN chmod +x /build/docker-reverse-proxy/bin/docker-reverse-proxy

FROM ${JFROG_DOCKER_REGISTRY}/alpine:3.17

COPY --from=builder /build/docker-reverse-proxy/bin/docker-reverse-proxy .

ENTRYPOINT [ "./docker-reverse-proxy" ]
