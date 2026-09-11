# Build stage
FROM swift:6.0-jammy AS builder

WORKDIR /app

# Copy package files first for better caching
COPY Package.swift Package.resolved* ./

# SwiftPM validates every target path, including tests, during a product build.
# Tests stay in the builder; the runtime image receives only the App executable.
COPY Tests ./Tests

# Resolve and fetch dependencies
RUN swift package resolve

# Pre-build dependencies in a cached layer
RUN mkdir -p Sources/App/Resources/Contractor && \
    touch Sources/App/Resources/Contractor/cache-placeholder && \
    echo 'import Vapor; print("dependency cache")' > Sources/App/main.swift && \
    swift build -c release --product App -j 1 && \
    rm -rf Sources

# Copy actual source code
COPY Sources ./Sources

# Build release binary
RUN swift build -c release --product App -j 1

# Runtime stage
FROM swift:6.0-jammy-slim

RUN apt-get update && apt-get install -y --no-install-recommends imagemagick curl ca-certificates && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd --create-home --user-group vapor

WORKDIR /app

# Copy built executable
COPY --from=builder /app/.build/release/App ./
COPY --from=builder /app/.build/release/SnaglistBackend_App.resources ./SnaglistBackend_App.resources

# Create Public directory for uploads and static file serving
RUN mkdir -p Public/uploads/synced-photos Public/uploads/synced-drawings

RUN chown -R vapor:vapor /app
USER vapor

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
