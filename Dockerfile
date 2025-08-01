# Build stage
FROM alpine:latest AS builder

# Install dependencies for building Zig applications
RUN apk add --no-cache \
    zig \
    libc-dev

# Set working directory
WORKDIR /app

# Copy source code
COPY . .

# Build the application
RUN zig build -Doptimize=ReleaseFast

# Runtime stage
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    libc6-compat

# Create non-root user
RUN addgroup -g 1001 -S semantic && \
    adduser -S semantic -u 1001 -G semantic

# Create directories
RUN mkdir -p /app/config /app/logs && \
    chown -R semantic:semantic /app

# Copy binary and resources from builder stage
COPY --from=builder /app/zig-out/bin/semantic-search /usr/local/bin/semantic-search
COPY --chown=semantic:semantic config/config.json /app/config/
COPY --chown=semantic:semantic examples/ /app/examples/
COPY --chown=semantic:semantic src/web/ /app/src/web/
COPY --chown=semantic:semantic setup/ /app/setup/

# Switch to non-root user
USER semantic

# Set working directory
WORKDIR /app

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD semantic-search --version || exit 1

# Expose HTTP port
EXPOSE 8080

# Default command: start web server
ENTRYPOINT ["/usr/local/bin/semantic-search"]
CMD ["server"]