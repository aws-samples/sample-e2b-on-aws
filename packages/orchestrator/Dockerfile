ARG JFROG_DOCKER_REGISTRY=artifactory.aic.aws.zoomdev.us/zoom-docker-virtual
FROM ${JFROG_DOCKER_REGISTRY}/golang:1.24-bullseye AS builder

ARG JFROG_ARTIFACTORY_URL=https://artifactory.aic.aws.zoomdev.us/artifactory
ENV GOPROXY=${JFROG_ARTIFACTORY_URL}/api/go/zoom-go-virtual

WORKDIR /build/shared

COPY .shared/go.mod .shared/go.sum ./
RUN go mod download

COPY .shared/pkg pkg

WORKDIR /build/orchestrator

COPY go.mod go.sum ./
RUN go mod download

COPY main.go Makefile ./
COPY internal internal

RUN go mod tidy

ARG COMMIT_SHA
RUN --mount=type=cache,target=/root/.cache/go-build make build-local COMMIT_SHA=${COMMIT_SHA}

FROM scratch

COPY --from=builder /build/orchestrator/bin/orchestrator .
