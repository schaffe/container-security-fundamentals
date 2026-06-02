---
title: "Image Minimization"
section: "Container Image Hardening"
order: 2
---

# Image Minimization

Container image minimization is the practice of reducing image size by eliminating build-time artifacts, unused dependencies, debug symbols, and intermediate layers. Smaller images mean faster pulls, less network transfer, reduced storage costs, and — critically — a smaller attack surface.

## Multi-stage Build Patterns

Multi-stage builds are the single most effective technique for image minimization. They allow separate build and runtime environments, copying only the compiled artifact into the final image.

### Go Application

```dockerfile
# Stage 1: Build with full toolchain
FROM golang:1.21 AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /app .

# Stage 2: Minimal runtime with scratch
FROM scratch
COPY --from=builder /app /app
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
EXPOSE 8080
CMD ["/app"]
```

The `scratch` base yields an image of ~8-15 MB for a Go binary vs ~300 MB for the full Go toolchain image.

### Python Application

```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --user --no-cache-dir -r requirements.txt

FROM python:3.12-slim
RUN useradd -m -u 10001 appuser
COPY --from=builder /root/.local /home/appuser/.local
COPY --from=builder /app /app
WORKDIR /app
USER appuser
# Adjust PATH to find pip-installed binaries
ENV PATH=/home/appuser/.local/bin:$PATH
CMD ["python", "main.py"]
```

Python is harder to minimize than Go because the runtime interpreter is required. The `slim` variants remove headers, static libraries, and documentation.

## COPY --from for Binary-Only Results

The `COPY --from=<stage>` syntax can copy individual files, not just entire directories:

```dockerfile
FROM node:20 AS build
WORKDIR /app
COPY package*.json .
RUN npm ci --only=production
COPY . .
RUN npm run build

FROM gcr.io/distroless/nodejs20-debian12
# Copy only the production dependencies
COPY --from=build /app/node_modules /node_modules
COPY --from=build /app/dist /dist
CMD ["/dist/server.js"]
```

### Selective File Copy Patterns

```dockerfile
# Copy only what's needed — not the entire builder stage
COPY --from=builder /app/bin/server /usr/local/bin/server
COPY --from=builder /app/config/prod.yaml /etc/app/config.yaml
# NOT: COPY --from=builder /app /app
```

## RUN Cleanup Chains

Every `RUN` instruction creates a new layer. Cleaning up in the same `RUN` is critical — otherwise the deleted files persist in a previous layer.

### Bad (packages persist in layer 1, then deleted in layer 2):

```dockerfile
RUN apt-get update && apt-get install -y build-essential   # Layer 1: ~200 MB added
RUN apt-get remove -y build-essential                       # Layer 2: marked deleted but space persists
```

### Good (single RUN with cleanup):

```dockerfile
RUN apt-get update && apt-get install -y build-essential && \
    make && \
    apt-get purge -y --auto-remove build-essential && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
```

### Package Manager Cleanup Commands

```dockerfile
# Debian/Ubuntu
RUN apt-get update && apt-get install -y --no-install-recommends pkg && \
    rm -rf /var/lib/apt/lists/*

# Alpine
RUN apk add --no-cache --virtual .build-deps build-base && \
    make && \
    apk del .build-deps

# The --virtual flag creates a virtual package that can be removed atomically

# RHEL/Ubi
RUN yum install -y make gcc && \
    make && \
    yum remove -y make gcc && \
    yum clean all && \
    rm -rf /var/cache/yum
```

## Layer Squash

After a Docker build, the image consists of many layers. Squashing collapses them into a single layer, removing intermediate files even if they span multiple `RUN` instructions.

```bash
# During build: squash all layers into one
docker build --squash -t myapp:squashed .

# BuildKit variant (no squash flag, but better layer caching)
DOCKER_BUILDKIT=1 docker build -t myapp:squashed .
```

Note: `--squash` is still experimental in some Docker versions. An alternative is using `docker-slim`:

```bash
docker-slim build myapp:latest
# Analyzes the image and removes unnecessary files
```

## Stripping Binaries

Debug symbols significantly increase binary size and serve no purpose in running containers.

### Stripping with ldflags (Go)

```dockerfile
# -s: omit symbol table and debug info
# -w: omit DWARF symbol table
RUN go build -ldflags="-s -w" -o /app .
```

### Stripping with strip command

```dockerfile
RUN apt-get update && apt-get install -y binutils && \
    strip --strip-all /app/binary && \
    strip --strip-unneeded /usr/local/lib/*.so && \
    apt-get purge -y --auto-remove binutils && \
    rm -rf /var/lib/apt/lists/*
```

### UPX Compression

UPX (Ultimate Packer for Executables) is an open-source tool that compresses executable files (EXEs, DLLs, ELF binaries, etc.) using run-time compression — it shrinks file size by compressing the binary, and a small decompression stub unpacks it in memory at runtime. Commonly used to reduce distribution size.

For additional size reduction, UPX compresses the binary:

```dockerfile
RUN apt-get update && apt-get install -y upx-ucl && \
    upx --best --lzma /app/binary && \
    apt-get purge -y --auto-remove upx-ucl && \
    rm -rf /var/lib/apt/lists/*
```

UPX trades runtime decompression overhead for image size. This is rarely worth it for container images because:
- Container images are already compressed during pull/docker save
- UPX can trigger antivirus false positives
- Decompression at startup adds latency

## Removing Unused Shared Libraries

Dynamic binaries pull in shared libraries that may not all be needed. Use `ldd` to audit and `strip` to remove unused sections.

### Audit shared library dependencies

```dockerfile
FROM debian:bookworm-slim AS builder
RUN apt-get update && apt-get install -y patchelf

# Copy the binary
COPY myapp /myapp

# List dynamic dependencies
RUN ldd /myapp

# Copy only required libraries
RUN mkdir /lib-stripped && \
    for lib in $(ldd /myapp | grep "=> /" | awk '{print $3}'); do \
        cp "$lib" /lib-stripped/; \
    done && \
    cp /lib64/ld-linux-x86-64.so.2 /lib-stripped/

FROM scratch
COPY --from=builder /myapp /myapp
COPY --from=builder /lib-stripped /lib64/
COPY --from=builder /lib-stripped /lib/
```

### Distroless as an Alternative

Rather than manually tracking library dependencies, use distroless base images which handle this automatically:

```dockerfile
# No need for ldd/copying — distroless includes the right glibc subset
FROM gcr.io/distroless/cc-debian12
COPY --from=build /app /app
```

## Combining Techniques: Production-Grade Minimization

```dockerfile
# === Stage 1: Build ===
FROM golang:1.21 AS builder
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app .

# === Stage 2: Runtime ===
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app /app
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
USER 65532:65532
EXPOSE 8080
CMD ["/app"]
```

## Results Comparison

| Technique | Base Image | Final Size |
|---|---|---|
| No minimization | golang:1.21 | ~1.2 GB |
| Multi-stage | scratch | ~12 MB |
| + ldflags -s -w | scratch | ~9 MB |
| + distroless | distroless/static | ~15 MB (includes CA certs) |
| + UPX compressed | scratch | ~4 MB |

## Supply Chain Security Impact

Smaller images reduce supply chain risk:

1. **Fewer packages = fewer CVEs**: Each removed transitive dependency eliminates a potential vulnerability vector
2. **Faster vulnerability scanning**: Scanning a 10 MB image vs a 500 MB image takes seconds vs minutes
3. **Reduced blast radius**: If compromised, the attacker has less tooling available in a minimal image
4. **SBOM accuracy**: A smaller, deterministic image produces a more accurate Software Bill of Materials

## Interview Tips

Know the **layer model** — each `RUN` creates a writable layer that persists even if files are deleted in subsequent layers. See [Image Layers & Storage Drivers](../docker/image-layers-storage-drivers.md) for a detailed look at how OverlayFS implements copy-on-write. The `COPY --from` is the most important minimization technique to discuss. Be ready to explain why `--squash` isn't widely adopted (it breaks layer caching, which is the primary benefit of BuildKit).
