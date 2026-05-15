FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /lifecycle-controller .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /lifecycle-controller /lifecycle-controller
ENTRYPOINT ["/lifecycle-controller"]
