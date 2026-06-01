# musl vs glibc: Choosing a C Standard Library for Containers

## Background

The Alpine vs distroless vs Ubuntu decision is ultimately a **libc decision**. Alpine uses **musl**; distroless and Ubuntu use **glibc**. Understanding the difference is critical for container security and compatibility.

**musl** is a lightweight, fast, standards-compliant C standard library implementation. It is the default libc in Alpine Linux (~5 MB base image vs Ubuntu's ~80 MB), which makes it one of the most widely deployed libcs in the container ecosystem.

## Comparison

| Dimension | musl (Alpine) | glibc (Debian, Ubuntu, distroless) |
|-----------|--------------|-------------------------------------|
| **Size** | ~700 KB | ~2 MB+ |
| **POSIX compliance** | Strict — rejects glibc extensions | De facto standard; many extensions |
| **Static linking** | First-class; Go/Rust binaries are natural fits | Possible but less common |
| **CVE history** | Smaller surface (less code, lower adoption) | Larger surface (more code, more scrutiny) |
| **Performance** | Fast for static binaries | Optimized for dynamic linking |

## Compatibility Pitfalls

- **glibc-specific APIs**: `GLOB_BRACE`, `strerrorname_np`, `qsort_r` do not exist in musl — code using them fails to compile on Alpine
- **DNS resolution**: musl handles `/etc/hosts` and NSS differently than glibc; Python's `urllib` and Node.js DNS may behave unexpectedly
- **Locale support**: musl has minimal locale support compared to glibc; applications relying on locale-aware string processing may produce different output

## Security Decision Framework

| Scenario | Recommended Base | Rationale |
|----------|-----------------|-----------|
| Static Go/Rust binary, minimal size goal | Alpine (musl) or distroless/static | No libc dependency at runtime; minimal CVE surface |
| Python/Node.js app, broad package availability | Debian slim or distroless (glibc) | glibc locale support; avoids DNS compatibility issues |
| Enterprise compliance, signed provenance | Wolfi-based distroless (musl) or DHI | Chainguard/Docker handle musl compatibility; you get attestations |
| FIPS 140-2/3 required | glibc-based (Ubuntu, UBI, distroless-cc) | FIPS-validated crypto modules target glibc; musl lacks CAVP certification |

musl's strictness is a double-edged sword: it catches portability bugs at compile time (good), but it means Alpine builds that pass CI may still fail on glibc-based production images (bad). Testing on the same libc as production is the only safe approach.

## See Also

- [Distroless Images](08-distroless-images.md) — distroless provides both glibc and musl variants
- [Image Minimization](09-image-minimization.md) — Alpine is a common choice for small images
