---
title: "Dependency Management Security"
section: "Supply Chain Security Theory"
order: 5
---

# Dependency Management Security

## Overview

Dependency management is the largest attack surface in modern software supply chains. The majority of code in a typical application is third-party — and every dependency is a potential vector. This article covers the major attack classes and defensive strategies.

## Attack Classes

### Dependency Confusion

An attacker publishes a package with the same name as an internal/private package to a public registry. Build tools that search public registries after (or instead of) private ones will install the malicious public package.

Example: your company uses `@mycorp/internal-auth` from a private npm registry. An attacker publishes `internal-auth` (without the scope) to npmjs.org. A misconfigured `npm install` resolves the public `internal-auth` instead of failing.

**Defense:**

```bash
# npm: scoped registries
npm config set @mycorp:registry https://npm.mycorp.com

# Prevent resolution from public registries
# .npmrc
registry=https://npm.mycorp.com
@mycorp:registry=https://npm.mycorp.com
```

```python
# pip: index-url per package
# requirements.txt
--extra-index-url https://private-pypi.mycorp.com/simple
my-private-pkg==1.0.0
```

Docker approach: use `--registry-mirror` pointing only to an internal proxy:

```json
{
  "registry-mirrors": ["https://docker-mirror.mycorp.com"]
}
```

### Typosquatting

Attackers publish packages with misspelled names of popular packages: `requsts` instead of `requests`, `urllib3` instead of `urllib3` (that one happened).

**Defense:**
- Use lockfiles (they pin exact versions and hashes)
- Run `npm audit` / `pip audit` before install
- Use registries that scan for lookalike names (npm's `package-name-conflicts` check)
- Pre-commit hooks to detect typo-squat patterns

### Repo-Jacking

An attacker registers a GitHub organization or username matching a repository that a package depended on, after the original owner deleted or abandoned it.

Example: package foo depends on `github.com/alice/lib-bar`. Alice deletes her account. Attacker registers `alice` and publishes malicious `lib-bar`.

**Defense:**
- Source hash pinning in lockfiles (includes the resolved commit)
- Internal mirrors of all dependencies (vendor directories, proxy caches)
- Never delete organizations or users from source hosting platforms — transfer instead

## Pinning Strategies

### Hash Pinning

Pin dependency content by its digest, not its version label. This is the gold standard for integrity.

```dockerfile
# Weak: tag-based
FROM node:20-alpine

# Stronger: digest pinning
FROM node:20-alpine@sha256:abc123...
```

```go
// go.sum entries are hash-pinned
github.com/gorilla/mux v1.8.1 h1:TuMFJxjvn8T3YvW7EupYaA8KBKXoAXQ=
```

**Tradeoffs:**
- ✅ Immutable reference — no tag mutation attacks
- ❌ Requires tooling to update (Dependabot, Renovate)
- ❌ Can become stale (no automatic security updates)

### Version Pinning (Exact)

Pin to a specific semantic version.

```python
# requirements.txt
requests==2.31.0
```

```json
// package.json
"dependencies": {
  "express": "4.18.2"
}
```

**Tradeoffs:**
- ✅ Reproducible builds (with lockfile)
- ❌ Version tags can be mutated (registry compromise)
- ❌ No hash verification without a lockfile

### Range Pinning

Allow semver-compatible updates automatically.

```json
"dependencies": {
  "express": "^4.18.0"
}
```

```python
# requirements.txt
requests>=2.31.0,<3.0.0
```

**Tradeoffs:**
- ✅ Automatic patch updates (may include security fixes)
- ❌ Malicious minor/patch version can enter without review
- ❌ Non-reproducible without lockfile

### Recommendation

Best practice is layered:

1. **Range pinning** in manifest (flexible for development)
2. **Lockfile** with content hashes (integrity)
3. **Automated dependency update** (Dependabot, Renovate) with CI verification
4. **Vendor/proxy** dependencies for air-gapped safety

## Lockfile Security

Lockfiles (go.sum, package-lock.json, Gemfile.lock, Cargo.lock, poetry.lock) pin every transitive dependency to specific versions with content hashes. They are the single most effective dependency security control.

```bash
# npm integrity: package-lock.json includes integrity hash
"lodash": {
  "version": "4.17.21",
  "integrity": "sha512-v2kDEe57lecTulaDIuNTPy3Ry4gLGJ6Z1O3vE1krgXZNrsQ+LFTGHVxVjcXPs17LhbZVGedAJv8XZ1tvj5FvSg=="
}
```

```go
# go.sum: multiple hashes per module version
github.com/gorilla/mux v1.8.1 h1:TuMFJxjvn8T3YvW7EupY...
github.com/gorilla/mux v1.8.1/go.mod h1:67gPMLoMrV+GYYiFqDMEcW9sC3W...
```

**Do not delete lockfiles.** Ever. They are the source of truth for what actually gets installed. Committing lockfiles is a security best practice — even in libraries.

## Package Manager-Specific Risks

### npm: postinstall scripts

npm packages can run arbitrary code during installation via the `postinstall` script. This is the vector for `event-stream` (the `flatmap-stream` backdoor).

```bash
# Disable lifecycle scripts globally
npm config set ignore-scripts true

# Or per-project in .npmrc
ignore-scripts=true

# Allow specific packages to run scripts
npm config set --engine-strict true
```

### pip: setup.py

Python packages can execute arbitrary code during `pip install` — `setup.py` is a Python file, not a declarative config. `pyproject.toml` (PEP 517/518) improves this but `setup.py` remains common.

```bash
# Use PEP 517-only mode
pip install --use-pep517 mypackage

# Install from wheel (pre-built, no setup.py execution)
pip install mypackage-1.0.0-py3-none-any.whl
```

### apt: install scripts

Debian packages can run `preinst` and `postinst` scripts during installation.

```bash
# Skip maintainer scripts (dangerous — may break package)
apt-get install -o DPkg::Options::=--force-confnew \
  -o DPkg::Options::=--force-confdef \
  docker-ce

# Or extract without installing
dpkg-deb -x package.deb ./extracted/
```

### RubyGems: gem install hooks

Ruby gems can define `pre_install` and `post_install` hooks. The `rest-client` gem incident (2019) demonstrated gem installation executing arbitrary code.

```bash
# Disable gem hooks
gem install --no-document --no-user-install mygem
```

## Defense in Depth Summary

| Layer | Tool/Control | Prevents |
|---|---|---|
| Registry configuration | Scoped registries, index-url | Dependency confusion |
| Lockfiles | package-lock.json, go.sum, Cargo.lock | Typosquatting, hash mismatch |
| Hash pinning | `@sha256:` in Dockerfiles | Tag mutation |
| CI verification | `npm audit`, `trivy fs`, `pip audit` | Known vulnerabilities |
| Proxy/mirror | Artifactory, Nexus, Docker registry mirror | Repo-jacking, registry compromise |
| Least privilege install | `--ignore-scripts`, `--use-pep517`, `no-install-recommends` | Post-install code execution |

## Common Interview Questions

- "Why commit lockfiles for libraries?" — Even library consumers benefit from knowing what versions the library was tested with; preventing surprise resolutions
- "How does dependency confusion differ from typosquatting?" — Confusion exploits namespace overlap between public and private registries; typosquatting exploits name misspelling. They're orthogonal — a typo-squatted package could also be a dependency confusion package
- "What is the single most impactful dependency security control?" — Lockfile with content hashes, committed to the repository, verified in CI
- "Should you use `npm audit` in CI?" — Yes, but as a gating mechanism only after evaluating the false positive rate for your ecosystem
