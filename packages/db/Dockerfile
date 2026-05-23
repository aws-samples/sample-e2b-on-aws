# Builder stage
ARG JFROG_DOCKER_REGISTRY=artifactory.aic.aws.zoomdev.us/zoom-docker-virtual
FROM ${JFROG_DOCKER_REGISTRY}/golang:1.24-alpine AS builder

ARG JFROG_ARTIFACTORY_URL=https://artifactory.aic.aws.zoomdev.us/artifactory
ENV GOPROXY=${JFROG_ARTIFACTORY_URL}/api/go/zoom-go-virtual

# Shared
WORKDIR /build/shared

COPY .shared/go.mod .shared/go.sum ./
RUN go mod download

COPY .shared/pkg pkg

#
WORKDIR /build/db

COPY go.mod go.sum ./
RUN go mod download

COPY scripts/migrator.go .

RUN go build -o ./migrator ./migrator.go
RUN chmod +x ./migrator

# Final stage
FROM ${JFROG_DOCKER_REGISTRY}/alpine:latest

COPY --from=builder /build/db/migrator /usr/local/bin/migrator

WORKDIR /app
COPY /migrations ./migrations

ENTRYPOINT ["migrator"]
