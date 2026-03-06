# Build stage
FROM swift:6.0-jammy as builder

WORKDIR /app

# Copy package files first for better caching
COPY Package.swift Package.resolved* ./

# Resolve and fetch dependencies
RUN swift package resolve

# Pre-build dependencies in a cached layer
RUN mkdir -p Sources/App && \
    echo 'import Vapor; @main struct Placeholder { static func main() async throws { print("x") } }' > Sources/App/main.swift && \
    (swift build -c release --product App -j 1 || true) && \
    rm -rf Sources

# Copy actual source code
COPY Sources ./Sources

# Build release binary
RUN swift build -c release --product App -j 1

# Runtime stage
FROM swift:6.0-jammy-slim

# Create non-root user
RUN useradd --create-home --user-group vapor

WORKDIR /app

# Copy built executable
COPY --from=builder /app/.build/release/App ./

# Create Public directory for uploads and static file serving
RUN mkdir -p Public/uploads/synced-photos Public/uploads/synced-drawings

RUN chown -R vapor:vapor /app
USER vapor

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
