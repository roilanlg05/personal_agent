FROM swift:5.10-jammy AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Package.swift Package.resolved ./
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --static-swift-stdlib --product memory-service

FROM swift:5.10-jammy-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/.build/release/memory-service /app/memory-service
EXPOSE 8081
ENTRYPOINT ["/app/memory-service"]
