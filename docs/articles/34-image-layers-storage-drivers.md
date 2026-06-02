---
title: "Image Layers & Storage Drivers"
section: "Docker"
order: 34
---

# Image Layers & Storage Drivers

Container images are not monolithic blobs. Every `docker build` produces a stack of layers, each
representing a filesystem delta. When a container starts, Docker stacks these layers into a unified
view using a storage driver — typically overlay2. Understanding the layer model and how storage
drivers compose layers into a writable filesystem is essential for debugging image size, optimizing
Dockerfiles, troubleshooting disk usage, and diagnosing runtime filesystem behaviour.

---

## Layer Concept

Every Dockerfile instruction that modifies the filesystem creates a **layer**. Instructions that
only set metadata — `ENV`, `WORKDIR`, `USER`, `VOLUME`, `EXPOSE`, `CMD`, `ENTRYPOINT`, `LABEL`,
`SHELL`, `MAINTAINER`, `ARG` — do not create layers. They update the image configuration JSON but
produce no filesystem delta.

A **layer** is a tar archive containing the files added, modified, or deleted by a single
instruction. Layers are stacked: applying layer N on top of layer N-1 produces the filesystem state
after instruction N.

```bash
$ docker history --no-trunc ubuntu:22.04
IMAGE          CREATED       CREATED BY                                      SIZE
d5c5f6f8e9a0   2 weeks ago   /bin/sh -c #(nop) CMD ["/bin/bash"]            0B
<missing>      2 weeks ago   /bin/sh -c #(nop) ADD file:abc... in /         77.9MB
```

The first line (`CMD`) shows `0B` — it produces no layer. The second line (`ADD` of the root
filesystem) shows `77.9MB` — it does produce a layer. Every layer after `FROM` adds to the stack.

```bash
$ docker history --no-trunc my-app:latest
IMAGE          CREATED       CREATED BY                                      SIZE
sha256:def...   5 min ago    CMD ["/app"]                                    0B
sha256:abc...   5 min ago    COPY app.sh /app.sh                             512B
sha256:base...  2 weeks ago  FROM ubuntu:22.04                               77.9MB
```

The `FROM ubuntu:22.04` layer is the base. Each subsequent instruction adds a delta on top.

---

## Layer Graph

Images use **content-addressable storage**: each layer is identified by its SHA-256 digest. The
digest is computed from the layer's tar content — if two builds produce identical tars, they share
the same digest and the same blob on disk.

```bash
$ docker image inspect ubuntu:22.04 | jq '.[0].RootFS'
{
  "Type": "layers",
  "Layers": [
    "sha256:2dc39ba0c4f3e1e3b5e0c2c5d5b6f7a8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b",
    "sha256:3ed4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d"
  ]
}
```

`RootFS.Layers` is an ordered list of layer digests from bottom to top. The runtime applies them in
sequence: layer[0] first, then layer[1] on top, and so on. The final filesystem is the union of all
layers.

Internally, each layer references its **parent** layer digest, forming a chain:

```
layer C (digest: sha256:c3...)
  └─ parent: sha256:b2...
layer B (digest: sha256:b2...)
  └─ parent: sha256:a1...
layer A (digest: sha256:a1...)
  └─ parent: <none>   ← base image layer
```

The image configuration records only the list of leaf digests — the chain is implicit in the layer
metadata stored on disk.

---

## Layer Sharing

Because layers are content-addressed, any two images that share a base layer store that layer's
blob **once** on disk. If ten images all start from `ubuntu:22.04`, the 77.9 MB root filesystem
layer is stored once and referenced by all ten image manifests.

```bash
$ docker system df
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          5         2         1.234GB   456.7MB (37%)
Containers      3         0         12.3kB    12.3kB (100%)
Local Volumes   2         1         1.234GB   0B (0%)
Build Cache     0         0         0B        0B
```

`docker system df` shows total image size and reclaimable space. The difference between total and
reclaimable is the shared layer data that cannot be pruned because at least one active image
references it.

Layer sharing is what makes Docker storage efficient: pulling a second Ubuntu-based image after the
first adds only the unique layers (the diff between the two Dockerfiles), not another full 77.9 MB
copy of Ubuntu.

---

## OverlayFS Theory

OverlayFS is a Linux union filesystem that merges multiple directories into a single view. It has
three key components:

- **lowerdir**: one or more read-only directories, stacked.
- **upperdir**: a single writable directory.
- **merged**: the union view that the process sees.

```
┌──────────────────────┐
│      merged          │  ← what the container sees
├──────────────────────┤
│      upperdir        │  ← writable layer (container's changes)
├──────────────────────┤
│      lowerdir        │  ← image layers (read-only)
│  ┌────┐ ┌────┐ ┌───┐ │
│  │ L1 │ │ L2 │ │L3 │ │
│  └────┘ └────┘ └───┘ │
└──────────────────────┘
```

### Reads

When a process reads a file from the merged view, OverlayFS:

1. Checks the **upperdir** first. If the file exists there, return it.
2. Falls through to the **lowerdir** layers in order (topmost lower first).
3. If the file does not exist in any layer, return `ENOENT`.

An upperdir file **shadows** the same path in lowerdir — the lower file is hidden, not removed.

### Writes

Writing to a file that exists in the lowerdir triggers **copy-up**:

1. OverlayFS copies the file from lowerdir to upperdir.
2. The write modifies the copy in upperdir.
3. The original in lowerdir remains untouched.

Copy-up happens on the **first write** to a file — subsequent writes modify the upper copy directly
with no additional overhead.

### Deletes

Deleting a file that exists in a lower layer does not modify the lower layer. Instead, OverlayFS
places a **whiteout** in the upperdir — a character device with major/minor 0/0. The whiteout tells
the merged view to hide the lower file.

```bash
$ ls -la /upperdir/
c--------- 2 root root 0, 0 .wh.target_file
```

When the whiteout is present, reads of `target_file` from merged return `ENOENT`, even though the
original still exists in the lower layer.

---

## OverlayFS in Docker

Docker uses OverlayFS to mount each container's filesystem. When a container starts:

- **lowerdir** = the image layers, stacked as read-only snapshots.
- **upperdir** = a thin writable directory created for this container (~0 bytes initially).
- **merged** = the union view mounted as the container's root filesystem.

```bash
$ cat /proc/self/mountinfo | grep overlay
36 29 0:28 / / rw,relatime - overlay overlay rw,
  lowerdir=/var/lib/docker/overlay2/l/K7Q3...:.../l/2W5P...,
  upperdir=/var/lib/docker/overlay2/abc123/diff,
  workdir=/var/lib/docker/overlay2/abc123/work
```

The `lowerdir` parameter lists layer directories, colon-separated, ordered from bottom to top (the
leftmost is the topmost lower layer). The `upperdir` is the container's writable layer. The `workdir`
is an internal OverlayFS scratch directory for atomic operations.

Docker stores layers under `/var/lib/docker/overlay2/`. Each layer has:

```
/var/lib/docker/overlay2/<layer-hash>/
├── diff/          ← the actual files in this layer
├── link           ← short name symlink (e.g., "L3X7...")
├── lower          ← parent layer reference
└── work/          ← OverlayFS workdir
```

The `link` file contains a short name (e.g., `L3X7...`) that Docker uses to avoid long mount path
issues. Symlinks in `/var/lib/docker/overlay2/l/` map short names to full layer hashes.

---

## Copy-on-Write

Copy-on-write (CoW) is the mechanism that prevents containers from modifying image layers. When a
container writes to a file from a lower layer:

1. OverlayFS detects the write targets a lower-layer file.
2. It **copies up** the file from lowerdir to upperdir.
3. The write completes against the upper copy.

The first write to any given lower-layer file is slower because of the copy-up. Subsequent writes
to the same file hit the upper copy directly and perform at native filesystem speed.

```
Before write (file is in lowerdir only):
  Process reads /etc/passwd → OverlayFS returns lowerdir copy
  Process writes /etc/passwd → copy-up triggered

After write (file now exists in upperdir):
  Process reads /etc/passwd → OverlayFS returns upperdir copy
  Process writes /etc/passwd → direct write to upperdir (no copy-up)
```

The copy-up only copies the **file** that is written, not the entire directory. A 1-byte write to
a 100 MB log file copies the full 100 MB to upper, then modifies 1 byte. For workloads that write
to large files, mount a volume or tmpfs mount to bypass CoW entirely.

Reading from the upper layer is also CoW — it shadows the lower file. The read itself is cheap (no
copy), but the upper copy occupies space for as long as the container lives (or until the file is
deleted from the writable layer).

---

## Container Layer Lifecycle

When `docker run` creates a container, Docker:

1. Creates a new writable layer directory under `/var/lib/docker/overlay2/`.
2. Mounts the overlay with image layers as lowerdir and the new directory as upperdir.
3. The overlay mount becomes the container's root filesystem.

```
docker run → new upperdir created → overlay mount → container starts
```

The writable layer is **thin** — it starts at ~0 bytes and grows only when the container writes new
files or triggers copy-up from lower layers. Containers that write large amounts of data (databases,
logs, caches) should use **volumes** or **bind mounts**, which bypass the overlay and mount directly
into the container's mount namespace at the target path.

When `docker rm` removes a container:

1. The overlay mount is unmounted.
2. The upperdir directory is deleted.
3. All data written by the container is lost (unless volumes were used).

```bash
$ docker create --name temp ubuntu:22.04 touch /data
$ docker start temp
$ docker rm temp   # /data is gone forever
```

If the container is **committed** via `docker commit`, the current state of the writable layer is
exported as a new image layer:

```bash
$ docker commit temp my-image:snapshot
```

The commit freezes the writable layer as a new immutable layer, which becomes part of the image
graph. This is how `docker build` works under the hood — each `RUN` instruction commits the
container's writable layer into the build cache.

---

## Storage Drivers

The storage driver is the component that manages how layers are stored and mounted. Docker supports
several drivers:

### overlay2 (default since Docker 18.09+)

The native Linux OverlayFS driver. It uses the kernel's OverlayFS module directly.

**Advantages:**
- Page cache sharing: multiple containers reading the same file from the same lower layer share
  kernel page cache entries. Memory usage scales with unique data, not total layers.
- Inode-efficient: uses one directory per layer, not one directory per file (unlike aufs).
- Fast mount/unmount: overlay mounts are instantaneous.
- CoW at the kernel level: copy-up is handled by VFS, not userspace.

**Requirements:** Linux kernel 4.0+ (ideally 4.18+ for metacopy and redirect_dir improvements).

### fuse-overlayfs (rootless mode)

Rootless Docker cannot mount kernel OverlayFS because it requires `CAP_SYS_ADMIN`. Instead,
rootless mode uses **fuse-overlayfs** — a FUSE implementation of OverlayFS that runs in userspace.

**Tradeoffs:**
- No page cache sharing (every container has its own cache).
- Slower copy-up (FUSE context switches dominate).
- Works without privileges, enabling rootless Docker on any modern kernel.

### aufs (deprecated)

Advanced multi-layered unification filesystem. Was the default before overlay2. Still supported for
compatibility but removed in Docker Engine 24+.

**Disadvantages:**
- Not in upstream Linux (needs patched kernel or DKMS).
- No page cache sharing.
- One directory per file in the union layer — high inode pressure on large images.

### devicemapper (deprecated)

Uses device-mapper thin provisioning to create block-level snapshots. Was the default on RHEL/CentOS
before overlay2.

**Disadvantages:**
- 10 GB default pool size (out-of-space errors on large images without manual config).
- No page cache sharing.
- CoW at block level — modifies 64 KB blocks even for 1-byte changes.
- `docker system df` shows misleading sizes (pool allocation, not actual data).

### overlay (deprecated)

The predecessor to overlay2. Single lowerdir only (cannot stack multiple lower layers). Replaced by
overlay2 which supports multiple lowerdirs natively.

### vfs (debug only)

No union filesystem at all. Every layer is a full copy of all previous layers. Used for testing and
environments where no union filesystem is available (e.g., some CI environments).

### Why overlay2 Wins

| Feature              | overlay2 | aufs | devicemapper | vfs   |
|----------------------|----------|------|--------------|-------|
| Page cache sharing   | Yes      | No   | No           | N/A   |
| Inode efficient      | Yes      | No   | Yes          | No    |
| Kernel supported     | Yes      | No   | Yes          | Yes   |
| CoW granularity      | File     | File | Block (64K)  | File  |
| Mount time           | Instant  | Fast | Slow         | N/A   |
| Default since        | 18.09    | —    | —            | —     |

Overlay2 is the default on all modern Linux distributions. Unless you run rootless Docker or a very
old kernel, you are using overlay2.

---

## Garbage Collection

Over time, Docker accumulates unused layers, build cache entries, and dangling images. Several
commands clean these up.

### docker image prune

Removes dangling images (images with no tag and no child image) and optionally all unused images:

```bash
# Remove dangling images only
docker image prune

# Remove all unused images (not referenced by any container)
docker image prune -a
```

### docker builder prune

BuildKit stores layers in its build cache. These are not visible to `docker image prune`:

```bash
# Remove all build cache
docker builder prune

# Keep only the last 24 hours of cache
docker builder prune --filter until=24h

# Show how much space would be freed
docker builder prune --dry-run
```

### docker system prune

The nuclear option — removes stopped containers, unused networks, dangling images, and build cache:

```bash
docker system prune -a --volumes
```

`--volumes` also removes anonymous volumes. Omitting it preserves volumes because they may contain
intentional data.

### BuildKit GC

BuildKit has its own garbage collection, configured in `/etc/buildkit/buildkitd.toml`:

```toml
[worker.oci]
  gc = true
  gckeepstorage = 10000  # keep 10 GB of cache

[worker.oci.gcpolicy]
  # Keep all cache entries used in the last 48 hours
  keepDuration = 172800  # 48 hours in seconds
  keepStorage = 5000     # target 5 GB of cache
  filters = [ "unused-for=48h" ]
```

BuildKit uses **LRU eviction**: when storage exceeds `keepStorage`, it deletes the oldest unused
cache entries first. The `keepDuration` filter exempts recently-used entries from eviction.

---

## docker save / docker load

`docker save` and `docker load` export and import images as tarballs while preserving the layer
structure.

### docker save

```bash
$ docker save ubuntu:22.04 -o ubuntu.tar
$ tar tvf ubuntu.tar
blobs/sha256/abc...   ← layer blob (gzipped tar)
blobs/sha256/def...   ← another layer blob
index.json            ← multi-arch index (if applicable)
oci-layout            ← OCI layout version
manifest.json         ← legacy Docker manifest
```

The exported tarball preserves each layer as a separate blob. The manifest references the blob
digests so the layer topology is intact on import.

```bash
# Save multiple images into one tarball
docker save ubuntu:22.04 alpine:3.19 -o images.tar
```

### docker load

```bash
$ docker load -i ubuntu.tar
Loaded image: ubuntu:22.04
```

`docker load` reads the tarball, verifies blob digests, extracts layers into
`/var/lib/docker/overlay2/`, and registers the image in the local image store. Layers that already
exist (matching digest) are skipped — this is the same deduplication as layer sharing.

### Exporting Individual Layers

For debugging, you can export a single layer from an image:

```bash
# Save image, extract a specific layer blob
docker save my-app:latest -o my-app.tar
tar xf my-app.tar blobs/sha256/abc123...
mkdir /tmp/layer && tar xzf blobs/sha256/abc123... -C /tmp/layer
```

This lets you inspect exactly what files a given instruction added or modified, without running
a container.

---

## Cross-References

- [Distroless Images](../articles/08-distroless-images.md) — how minimal base images shrink the
  layer footprint and reduce attack surface.
- [Image Minimization](../articles/09-image-minimization.md) — techniques for reducing layer count
  and size through multi-stage builds and layer squashing.
- [Read-only Filesystems](../articles/14-readonly-filesystem.md) — how read-only root works with
  overlay upperdir and what it prevents.
- [Scanner Internals](../articles/20-scanner-internals.md) — how vulnerability scanners decompress
  and analyse image layers to extract package databases.
- [How Docker Builds Images](../articles/33-how-docker-builds-images.md) — the layer export pipeline
  from the differ through content-addressed storage to manifest assembly.
