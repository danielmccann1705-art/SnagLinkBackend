# Build stage - used by GitHub Actions
FROM swift:5.9-jammy as builder

WORKDIR /app

# Copy package files first for better caching
COPY Package.swift Package.resolved* ./

# Resolve and fetch dependencies
RUN swift package resolve

# Pre-build dependencies in a cached layer
# Use baseline x86-64 CPU target to avoid SIGILL on Render's machines
RUN mkdir -p Sources/App && \
    echo 'import Vapor; @main struct Placeholder { static func main() async throws { print("x") } }' > Sources/App/main.swift && \
    (swift build -c release --product App -j 2 -Xswiftc -target-cpu=x86-64 -Xcc -march=x86-64 || true) && \
    rm -rf Sources

# Copy actual source code
COPY Sources ./Sources

# Build release binary with limited parallelism
# Target baseline x86-64 to ensure compatibility with Render's runtime CPUs
RUN swift build -c release --product App -j 2 -Xswiftc -target-cpu=x86-64 -Xcc -march=x86-64

# Runtime stage
FROM swift:5.9-jammy-slim

# Install minimal runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd --create-home --user-group vapor

WORKDIR /app

# Copy built executable
COPY --from=builder /app/.build/release/App ./

RUN chown -R vapor:vapor /app
USER vapor

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
