FROM golang:1.25.1-alpine3.22 AS builder
WORKDIR /app
ENV GO111MODULE=on GOPROXY=https://goproxy.cn,direct
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o ./bin/server .

FROM alpine:3.22
WORKDIR /app
COPY --from=builder /app/bin/server /app/server
COPY --from=builder /app/config /app/config
RUN chmod +x /app/server
EXPOSE 1423
CMD ["./server"]
