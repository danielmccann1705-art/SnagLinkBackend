# Build stage
FROM swift:5.9-jammy as builder

WORKDIR /app

# Copy package files first for better caching
COPY Package.swift Package.resolved* ./

# Resolve and fetch dependencies
RUN swift package resolve

# Pre-build dependencies in a cached layer
# CRITICAL: Use static-swift-stdlib to include stdlib in binary (compiled with our flags)
# Disable ALL vectorization to prevent ANY AVX/AVX2 instructions
RUN mkdir -p Sources/App && \
    echo 'import Vapor; @main struct Placeholder { static func main() async throws { print("x") } }' > Sources/App/main.swift && \
    (swift build -c release --product App -j 2 --static-swift-stdlib \
        -Xswiftc -target-cpu -Xswiftc x86-64 \
        -Xswiftc -Xllvm -Xswiftc -vectorize-loops=false \
        -Xswiftc -Xllvm -Xswiftc -vectorize-slp=false \
        -Xcc -march=x86-64 -Xcc -mtune=generic -Xcc -mno-avx -Xcc -mno-avx2 -Xcc -mno-avx512f || true) && \
    rm -rf Sources

# Copy actual source code
COPY Sources ./Sources

# Build release binary with limited parallelism
# CRITICAL FLAGS FOR RENDER COMPATIBILITY:
# --static-swift-stdlib: Statically link Swift stdlib (uses OUR compilation flags)
# -target-cpu x86-64: Target baseline x86-64 without AVX
# -vectorize-loops=false: Disable loop vectorization (prevents AVX auto-generation)
# -vectorize-slp=false: Disable SLP vectorization (prevents AVX auto-generation)
# -Xcc flags: Ensure C code also avoids AVX
RUN swift build -c release --product App -j 2 --static-swift-stdlib \
    -Xswiftc -target-cpu -Xswiftc x86-64 \
    -Xswiftc -Xllvm -Xswiftc -vectorize-loops=false \
    -Xswiftc -Xllvm -Xswiftc -vectorize-slp=false \
    -Xcc -march=x86-64 -Xcc -mtune=generic -Xcc -mno-avx -Xcc -mno-avx2 -Xcc -mno-avx512f

# Runtime stage - using Ubuntu base since we statically linked Swift
FROM ubuntu:22.04

# Install minimal runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd --create-home --user-group vapor

WORKDIR /app

# Copy built executable
COPY --from=builder /app/.build/release/App ./

# CRITICAL: Force BoringSSL/OpenSSL to NOT use AVX instructions at runtime
# The hand-written assembly in BoringSSL (aes-gcm-avx2-x86_64.S, etc.) uses AVX
# This env var tells BoringSSL to disable AVX/AVX2/AVX512 feature detection
# Format: ~bit_mask clears those bits from CPUID detection
# Bit 28 (0x10000000) = AVX in CPUID(1).ECX
# Bit 5 (0x20) = AVX2 in CPUID(7).EBX
# We clear all AVX-related bits to force fallback to SSE implementations
ENV OPENSSL_ia32cap="~0x200000000000000:~0x20"

RUN chown -R vapor:vapor /app
USER vapor

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
