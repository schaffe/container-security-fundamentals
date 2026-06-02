---
title: "Build Context"
section: "Docker"
order: 31
---

# Build Context

## What Is the Build Context

When you run `docker build`, the Docker client gathers all files and directories specified as the
**build context** and sends them to the Docker daemon (or directly to BuildKit). The daemon uses
this context as the source of files that `COPY`, `ADD`, and other instructions reference.

```bash
docker build -t my-app:latest .
```

The final argument (`.`) is the build context path. Everything under that directory gets packed up
and shipped to the daemon — your Dockerfile, source code, configs, and unfortunately also your
`node_modules`, `.git`, `.env`, build artifacts, and anything else in that tree.

---

## Default Context Behaviour

The context is always a directory, **not** a Dockerfile location. This is a common pitfall:

```bash
docker build -f docker/Dockerfile.prod .
```

Even though the Dockerfile lives in `docker/`, the context is still `.` — the entire project
directory gets tarred and sent to the daemon. The `-f` flag only tells the daemon where to find the
Dockerfile *inside* the context; it does not change what gets sent.

To send only the `docker/` directory you must explicitly point context there:

```bash
docker build -f docker/Dockerfile.prod docker/
```

But then path references in the Dockerfile must be relative to `docker/`, which often means you
cannot access source files in parent directories — a design tradeoff that `.dockerignore` exists to
solve.

---

## .dockerignore Syntax

A `.dockerignore` file lives at the root of the build context and tells the daemon which files to
exclude from the context tarball. The syntax follows Go's `filepath.Match` rules with some
extensions:

| Pattern | Behaviour |
|---------|-----------|
| `*` | Matches any sequence of non-separator characters in a single path element |
| `?` | Matches any single non-separator character |
| `**/` | Matches zero or more directories (recursive) |
| `**` | Matches everything (files and directories recursively) |
| `!pattern` | Negation — re-include a previously excluded file |
| `# comment` | Ignored line |
| Leading whitespace | Trimmed |

### Negation Gotcha

Once a directory is excluded, `!` cannot re-include files inside it. The parent must be
re-included first:

```
node_modules
!node_modules/important-module
```

This does **not** work because `node_modules` is fully excluded. You need:

```
node_modules/*
!node_modules/important-module
```

This excludes only the contents of `node_modules`, then re-includes the specific subdirectory.

### Relative to Context Root

`.dockerignore` paths are relative to the build context root, not the Dockerfile location. If your
context is `..` (parent directory), patterns reference paths from there.

---

## Impact on Build Performance

A large context directly increases build time. The client must:

1. Read every file from disk
2. Tar the entire tree
3. Send the tarball over HTTP to the daemon API

The "Sending build context to Docker daemon" message shows the size:

```bash
$ docker build -t big-app .
Sending build context to Docker daemon  842.6MB
```

With a ~800 MB context (hello, `node_modules` + build artifacts), the upload alone can take 10–30
seconds over a local socket and much longer over a remote daemon.

### BuildKit Progress

BuildKit (default since Docker 23.0) replaces the "Sending build context" line with inline progress
bars. It still sends the full context, but the progress display is different:

```
#1 [internal] load build context
#1 transferring context: 842.6MB 15.3s
```

The underlying mechanism is the same — BuildKit just shows progress more granularly.

### Timing Comparison

| Context Size | Transfer Time (local socket) | Transfer Time (remote daemon) |
|-------------|------------------------------|-------------------------------|
| 10 KB       | < 0.1 s                      | < 0.1 s                      |
| 10 MB       | ~0.2 s                       | ~0.5 s                       |
| 100 MB      | ~2 s                         | ~5–10 s                      |
| 1 GB        | ~20 s                        | ~1–2 minutes                 |

Remote daemons (CI runners, cloud builders) make the penalty worse — every byte crosses the
network. A proper `.dockerignore` often cuts context size by 10–100×.

---

## Context as Tarball

The Docker client does not stream files individually. It creates a tar archive of the entire context
on disk, then sends it to the daemon's `/build` API endpoint:

```bash
# This is roughly what the CLI does internally
tar cf - . | curl -X POST \
  --data-binary @- \
  --unix-socket /var/run/docker.sock \
  http://localhost/v1.46/build?t=my-app
```

The daemon receives the tarball, extracts it into a temporary directory (or, with BuildKit, passes
it as a `local` source to the LLB graph), and makes the files available to `COPY` / `ADD`
instructions.

This means **every file** in the context gets read from disk and compressed, even files the
Dockerfile never uses. The `.dockerignore` is the only filter.

---

## .dockerignore as Security Boundary

Perhaps the most overlooked role of `.dockerignore` is **security**. Files sent to the daemon end up
in the layer cache, exported tarballs, and potentially in production images if a build step leaks
them. Common things that must never appear in a build context:

```
.env
.env.*
node_modules/
.git/
.gitignore
target/
build/
dist/
__pycache__/
*.pyc
*.log
secrets/
*.pem
*.key
id_rsa*
.aws/
.gcloud/
.terraform/
*.tfstate
```

Each of these reveals something about the development environment, credentials, or infrastructure
that a production image should never contain. Even if the Dockerfile does not `COPY` these files,
they travel over the socket and sit in the daemon's temp directory — and anyone with access to the
daemon or the build cache can retrieve them.

### Docker Build Secrets (The Right Way)

Instead of sending secrets in the context, use BuildKit's `--secret` flag:

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=secret,id=api_key \
  cat /run/secrets/api_key > /app/config.toml
```

```bash
docker build --secret id=api_key,src=.env.prod .
```

The secret never enters the context, never lands in a layer, and is only available to the specific
`RUN` instruction that mounts it.

---

## Remote Contexts

Docker supports sourcing the build context from remote locations:

### Git Repositories

```bash
docker build https://github.com/user/repo.git#main:src/app
```

This clones the repository (or fetches a specific commit/branch), checks out the subdirectory
`src/app`, and uses that as the context. The Dockerfile must exist inside that subdirectory unless
`-f` provides a path relative to it.

Under the hood, Docker delegates to `git clone --depth=1` and pipes the checkout as the context
tarball.

### Stdin

```bash
docker build - < context.tar.gz
```

Useful in CI pipelines where the context is produced by a previous step. Docker reads the tarball
from stdin and passes it directly to the daemon.

```bash
tar czf - src/ Dockerfile | docker build -t my-app -
```

The `-` signals "context from stdin." The daemon receives the tarball as-is — no `.dockerignore`
processing happens because the client never walks the filesystem.

---

## BuildKit's `local` Source

Internally, BuildKit represents the build context as a **`local` source** in its LLB (low-level
builder) graph. When you run `docker build`, BuildKit creates an LLB operation that reads from a
local directory:

```go
// Conceptual LLB representation
sourceOp := llb.Local("context", llb.IncludePattern("src/**"),
  llb.ExcludePattern("node_modules/**"),
  llb.SharedKeyHint("my-app"))
```

The `local` source type means:

- Files are served from the client side (mounted via FUSE or preloaded via tarball)
- BuildKit applies include/exclude patterns (derived from `.dockerignore`)
- The local source is cacheable — if the same directory is used in multiple builds, BuildKit skips
  re-uploading if nothing changed

This is a significant difference from the classic builder, which re-sends the entire context every
time. BuildKit's session-based architecture streams the context once per session, and subsequent
builds reuse it if the session is still alive (e.g., `docker buildx build` with the same builder
instance).

The LLB representation allows BuildKit to parallelize context loading with other build operations.
For details on LLB, see [BuildKit Internals](../articles/32-buildkit-internals.md).

---

## Practical .dockerignore Examples

### Node.js

```
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*
.env
.env.*
.git
.gitignore
coverage/
.nyc_output/
dist/
.next/
*.ts
!src/**/*.ts
```

The `!src/**/*.ts` pattern keeps TypeScript source files (for `ts-node` or build step) while
excluding root-level `.ts` files like configs.

### Go

```
.git/
.env
*.exe
*.test
*.out
vendor/
```

Go binaries are statically linked; the `vendor/` directory is only needed if you use it and your
Dockerfile copies it explicitly. Otherwise, exclude it — it adds tens of thousands of files.

### Python

```
__pycache__/
*.py[cod]
*$py.class
*.so
.env
.git/
.venv/
venv/
env/
*.egg-info/
dist/
build/
.tox/
.coverage
htmlcov/
.pytest_cache/
```

Python projects accumulate cache directories rapidly. `__pycache__` alone can have tens of thousands
of files in a large monorepo.

### Java (Maven / Gradle)

```
.git/
.env
target/
build/
*.class
*.jar
!target/*.jar
.gradle/
.local/
.idea/
*.iml
*.ipr
*.iws
```

The `!target/*.jar` pattern keeps the built artifact if your Dockerfile copies it from `target/`,
while excluding the rest of the build directory.

---

## Best Practices

1. **Put `.dockerignore` at the context root**, not next to the Dockerfile. They are unrelated
   paths — the context root determines where `.dockerignore` is read from.

2. **Start with a broad exclude list** and open only what you need:

   ```
   *
   !src/
   !requirements.txt
   !Dockerfile
   ```

   This "deny-all" approach is explicit about what enters the build.

3. **Run `docker build` from a clean context directory** — ideally a CI checkout or a dedicated
   build directory rather than a developer's full working tree.

4. **Check context size** before building:

   ```bash
   docker build -t test . --no-cache 2>&1 | head -5
   # or use buildx inspect
   docker buildx du
   ```

5. **Use `COPY --link` with BuildKit** to avoid re-sending context when only files change:

   ```dockerfile
   COPY --link src/ /app/src/
   ```

   The `--link` flag uses content-addressed snapshots so unchanged files do not invalidate the
   cache for subsequent build stages.

6. **Never send secrets through the context.** Use BuildKit's `--secret` or `--ssh` flags, or
   multi-stage builds that copy credentials into an intermediate stage and discard it.

7. **Keep the context small by design.** A project with a 10 KB context builds faster, caches more
   reliably, and has a smaller attack surface than one with 500 MB of cruft. The `.dockerignore` is
   not a workaround for a poorly structured repository — it is a guardrail.

For a deeper look at how the build pipeline processes the context from Dockerfile to layer diff,
see [How Docker Builds Images](../articles/33-how-docker-builds-images.md).

---

## Summary

The build context is the set of files shipped to the Docker daemon for every build. It is tarred,
sent over HTTP, and extracted — and whatever you include stays in the daemon's cache. A well-crafted
`.dockerignore` is the single most effective optimisation for build speed, cache efficiency, and
security. Understand what your context contains, measure it, and exclude everything that does not
belong in the build.
