---
title: "CVE Fix Categorization and Strategies"
section: "CVE Lifecycle"
order: 23
---

# CVE Fix Categorization and Strategies

Not all CVEs can be fixed the same way. Some have upstream patches, some require backports, some have no fix at all, and some must be mitigated at runtime. A Senior Supply Chain Security Engineer needs to categorize vulnerabilities by fix status and select the appropriate remediation strategy — then communicate that plan to customers and leadership.

## Fixable vs Unfixable CVEs

The first categorization is whether a fix exists:

| Category | Definition | Example |
|----------|------------|---------|
| **Fix available** | Upstream maintainer or distro has published a patched version | `bash 5.2.15` → `bash 5.2.26` |
| **Backport available** | Distro has patched a specific version without rebasing the entire package | `libcrypto3 3.1.4-r2` → `3.1.4-r3` (same upstream, different patch level) |
| **No fix yet** | CVE is published, maintainer is working on patch | CVE-2021-44228 (Log4j) day 0 |
| **Won't fix** | Maintainer has declined to fix (end-of-life, low severity, breaking change) | Older Alpine packages in edge repos |
| **Introduced by fix** | Regression from a security patch creates a new CVE | CVE-2023-38178 (introduced by fix for another issue) |

## OS Package vs Language Library CVEs

This distinction determines the entire remediation approach.

### OS Package CVEs

OS packages (glibc, libcrypto, bash, curl) are typically managed through the distribution's package manager. Fixes come as **backported patches** — the distro cherry-picks the fix commit onto the existing version without bumping the upstream version.

```
RHEL 8: libcurl-7.61.1-34.el8 → libcurl-7.61.1-34.el8_10  (backport)
Alpine: libcrypto3-3.1.4-r2 → libcrypto3-3.1.4-r3          (backport)
Ubuntu 22.04: curl-7.81.0-1ubuntu1.18 → 7.81.0-1ubuntu1.19 (backport)
```

Scanners detect OS fixes by checking the **release field** (the suffix after the version). Trivy, Grype, and Scout all distinguish between the upstream version and the distro-specific release.

**Remediation**: Rebuild the container image with the latest base image tag, or pin to a specific patched version.

```bash
# Find the patched base image
docker scout recommendations alpine:latest

# Rebuild with specific patched base
FROM alpine:3.19.3  # instead of alpine:3.19
```

### Language Library CVEs

Language ecosystem CVEs (npm, PyPI, Go modules, Maven) are resolved by updating the dependency version in the lockfile or manifest. The scanner identifies the vulnerability through the lockfile's resolution graph.

```json
// package.json before
"lodash": "^4.17.20"

// After — lockfile updated via npm audit fix
"lodash": "4.17.21"
```

**Remediation**: Update the dependency in the manifest, regenerate the lockfile, and rebuild. For transitive dependencies, tools like `npm audit fix --force` or `go mod tidy` handle transitive resolution.

## Backport Patches vs Rebase

Understanding the distro's patching strategy is essential for accurate CVE reporting:

**Backport strategy** (RedHat, Debian, Ubuntu, Alpine):
- Maintain a stable major version (e.g., `curl 7.61.1` for RHEL 8)
- Cherry-pick security fixes from upstream
- Increment the release suffix (e.g., `-34.el8` → `-34.el8_10`)
- Low risk of breaking ABI/API compatibility
- Scanners report the **release field** to determine fix status

**Rebase strategy** (rolling releases, some language ecosystems):
- Update to the latest upstream version
- Includes all features, not just security fixes
- Higher risk of breaking changes
- Never use for enterprise — impossible to verify ABI stability

**Interview insight**: A scanner that doesn't understand backport versions will falsely report a CVE as "unfixed" on RHEL. The package version hasn't changed upstream, but the distro has fixed it. This is why scanner quality depends on ecosystem-specific version parsing.

## Handling "Won't Fix" CVEs

Maintainers decline to fix for several reasons:

1. **End of life**: The package version is no longer supported. Upgrade to a supported major version.
2. **Low severity**: The CVE requires physical access or unusual conditions. Accept the risk.
3. **Breaking change**: The fix would break ABI compatibility. Mitigate at runtime.
4. **Not reproducible**: The maintainer cannot confirm the vulnerability. Monitor for updates.

When a CVE is wontfix, the scanner should report it distinctly — not as "unfixed" (which implies a fix exists but isn't applied) but as "wontfix" (which implies the maintainer has made a deliberate decision).

```bash
# Trivy shows wontfix separately
trivy image --show-suppressed alpine:latest
```

## Remediation Strategies

Ordered by preference:

### 1. Rebuild with Patched Base Image

```bash
docker build --pull -t my-app:latest .
```

If the base image has been updated to include the fix, a simple rebuild resolves all OS-package CVEs.

### 2. Pin Specific Package Version

For Alpine, install a specific patched version:

```dockerfile
FROM alpine:3.19
RUN apk add --no-cache curl=8.5.0-r0
```

### 3. Apply Upstream Patch

When no distro backport exists, apply the upstream patch during the build:

```dockerfile
FROM alpine:3.19
RUN wget https://github.com/curl/curl/commit/abc123.patch \
  && patch -p1 < abc123.patch
```

### 4. Mitigate at Runtime

When no fix exists, reduce the attack surface:

```bash
docker run --security-opt seccomp=block-some-syscalls my-app
docker run --read-only --tmpfs /tmp my-app
docker run --cap-drop ALL --cap-add NET_BIND_SERVICE my-app
```

### 5. Accept the Risk

For low-severity CVEs with no exploit path in your environment, formally accept:

```yaml
# .trivyignore
CVE-2024-12345 # Low severity, requires physical access, not applicable
```

## Real CVE Examples

### Log4j (CVE-2021-44228)

- **Type**: Language library (Java/Maven)
- **Fix status**: Fix available (2.17.0, 2.12.4, 2.3.2)
- **Timeline**: CVE published Dec 9, 2021; fix released Dec 13 (4 days)
- **Challenge**: Tens of thousands of Java applications needed to update a transitive dependency. Many organizations had no SBOM and couldn't find where Log4j was used.
- **Lesson**: SBOM generation is not optional. You cannot remediate what you cannot see.

### runC (CVE-2024-21626)

- **Type**: OS package (container runtime)
- **Fix status**: Backport available (runc 1.1.12)
- **Timeline**: CVE published Jan 31, 2024; fix same day
- **Challenge**: Container escapes affect the entire host. Mitigation required immediate runtime controls while images were rebuilt.
- **Lesson**: Runtime CVEs require both image-level fixes and runtime mitigation. Seccomp, AppArmor, and user namespaces buy you time.

### libcrypto (CVE-2023-4807)

- **Type**: OS package (Alpine/RHEL)
- **Fix status**: Backport available (3.1.4-r3)
- **Challenge**: OpenSSL/libcrypto is in nearly every container. A fix here triggers a mass rebuild across all images using Alpine or RHEL base.
- **Lesson**: Track your base image inventory. Know which teams use which base image so you can coordinate rebuilds.

## Communicating Fix Timelines to Customers

For a Docker Scout product context, customers need clear communication:

```
CVE-2024-21626 (runc)
───────────────────────────────────────────
Severity:     CRITICAL (CVSS 8.6)
EPSS:         0.931 (93.1% exploit prob.)
Fix status:   Fix available in runc 1.1.12
Affects:      All images with runc < 1.1.12
Action:       Rebuild images on Docker 25.0+
Timeline:     Immediate — patch now
───────────────────────────────────────────
```

For SLAs with customers:
- **Critical + fix available**: Patch within 24 hours
- **Critical + no fix**: Runtime mitigation within 24 hours, patch when available
- **High + fix available**: Patch within 7 days
- **High + no fix**: Runtime mitigation within 7 days, reassess weekly
- **Medium/Low**: Patch within next maintenance window (30-90 days)

The key interview message: CVE fix categorization is not a technical exercise — it's a **communications and risk management discipline**. The best categorization is useless if teams can't effectively coordinate remediation.
