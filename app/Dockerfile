# Build stage runs on the builder's native arch and cross-compiles Go,
# so multi-arch builds need no emulation.
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /bin/hello .

FROM alpine:3.22
COPY --from=build /bin/hello /hello
EXPOSE 8080
USER nobody
ENTRYPOINT ["/hello"]
