# powerkey-issuer — 薄发码服务（单文件 Go，无外部依赖）
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/powerkey-issuer .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates \
 && adduser -D -u 10001 app \
 && mkdir -p /data && chown app /data
COPY --from=build /out/powerkey-issuer /usr/local/bin/powerkey-issuer
USER app
VOLUME /data
EXPOSE 8800
ENTRYPOINT ["/usr/local/bin/powerkey-issuer"]
