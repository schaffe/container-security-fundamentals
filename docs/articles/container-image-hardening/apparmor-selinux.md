---
title: "AppArmor and SELinux for Containers"
section: "Container Image Hardening"
order: 6
---

# AppArmor and SELinux for Containers

AppArmor and SELinux are Linux Security Modules (LSMs) that enforce mandatory access control (MAC) policies beyond the standard discretionary access control (DAC) model of Unix permissions. In container contexts, they provide an additional layer of defense that constrains what a containerized process can access even if it runs as root.

## AppArmor Overview

AppArmor (Application Armor) associates each process with a security profile that restricts file access, network operations, capability use, and inter-process communication. It uses path-based enforcement — policies are defined in terms of file paths.

Ubuntu and Debian-based systems use AppArmor by default. RHEL/CentOS/Fedora use SELinux.

### Per-Container Profiles

Docker applies an AppArmor profile named `docker-default` automatically (if AppArmor is loaded on the host):

```bash
# Check if AppArmor is loaded
cat /sys/module/apparmor/parameters/enabled
# Output: Y

# List loaded profiles (Docker creates docker-default automatically)
sudo aa-status | grep docker
# Output: docker-default (enforce)
```

### Docker's Default AppArmor Profile

The `docker-default` profile allows:
- Full access to the container's filesystem (`/**` — all files and directories)
- Network access (AF_INET, AF_UNIX, AF_NETLINK sockets)
- Capability checks (controlled by `--cap-add`/`--cap-drop`)
- [ptrace](seccomp.md#ptrace) on other processes in the same container (with `ptrace (trace)` peer permission)
- Standard signal delivery

The profile denies:
- Writing to [`/proc/sys/`](../linux-fundamentals/proc-container-isolation.md#3-procsys-kernel-parameter-modification) (kernel parameter modification)
- Writing to `/sys/` (kernel object modification)
- Mounting filesystems
- Access to [`/proc/kcore`](../linux-fundamentals/proc-container-isolation.md#2-prockcore-full-kernel-memory) (kernel memory)
- Access to [`/proc/sched_debug`](../linux-fundamentals/proc-container-isolation.md#attack-surface-via-proc-in-containers)
- `capability sys_admin` (even if the capability is granted)

```bash
# Inspect the Docker AppArmor profile
sudo aa-status
sudo cat /etc/apparmor.d/docker  # Usually auto-generated
```

### Writing Custom AppArmor Profiles

Custom profiles provide fine-grained control:

```bash
# /etc/apparmor.d/contnginx
#include <tunables/global>

profile contnginx flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  # Allow nginx binary
  /usr/sbin/nginx ix,

  # Log files
  /var/log/nginx/*.log rw,

  # Configuration
  /etc/nginx/** r,

  # Web content
  /usr/share/nginx/html/** r,

  # Temp files
  /var/lib/nginx/** rwk,
  /tmp/** rw,

  # Deny everything else
  deny /** w,
  deny /proc/** rw,
  deny /sys/** rw,
  deny capability sys_admin,
  deny network raw,
}
```

Apply the profile:

```bash
# Load the profile
sudo apparmor_parser -r /etc/apparmor.d/contnginx

# Run with the custom profile
docker run --security-opt apparmor=contnginx nginx

# Or in runc directly
runc run --apparmor=contnginx mycontainer
```

## SELinux Overview

SELinux (Security-Enhanced Linux) is a kernel security module that enforces MAC through **type enforcement** and **role-based access control (RBAC)**. Every process runs in a security context (domain), and every object (file, socket, etc.) has a security context. SELinux policies define which domains can access which objects.

RHEL, CentOS, Fedora, and Amazon Linux use SELinux by default. Most container environments on these distributions use **container-selinux** package.

### Type Enforcement for Containers: svirt_lxc_net_t

SELinux labels are structured as `user:role:type:level`:

```
unconfined_u:object_r:svirt_sandbox_file_t:s0:c123,c456
```

For containers, SELinux uses:
- **`svirt_lxc_net_t`**: The domain for container processes
- **`svirt_sandbox_file_t`**: The type for container files
- **Multi-Category Security (MCS)**: Each container gets a unique pair of categories (`s0:c123,c456`) to isolate containers from each other

This labeling ensures:
- Container processes (svirt_lxc_net_t) can read container files (svirt_sandbox_file_t)
- Container processes cannot read host files (etc_t, bin_t, etc.)
- Container A cannot read Container B's files (different MCS categories)

```bash
# Check SELinux status
getenforce
# Output: Enforcing

# Check container security context
docker run --rm alpine cat /proc/1/attr/current
# Output: system_u:system_r:svirt_lxc_net_t:s0:c123,c456

# Run without SELinux confinement (not recommended)
docker run --security-opt label=disable alpine

# Set custom SELinux label
docker run --security-opt label=type:myapp_t --security-opt label=level:s0:c100,c200 alpine
```

### Container-SELinux Policies

Installation:

```bash
# RHEL-based
sudo yum install -y container-selinux
sudo setenforce 1
```

The `container-selinux` package defines:
- `container_t`: Type for container processes
- `container_file_t`: Type for container file systems
- `container_var_lib_t`: Type for `/var/lib/containers`
- `container_log_t`: Type for container logs

## How AppArmor and SELinux Interact with Seccomp and Capabilities

These security mechanisms operate at different layers:

```
┌────────────────────────────────────┐
│         Application Code          │
├────────────────────────────────────┤
│  Capabilities (priveleged ops)     │  ← Fine-grained root privileges
├────────────────────────────────────┤
│  Seccomp (syscall filtering)       │  ← Kernel interface filtering
├────────────────────────────────────┤
│  AppArmor / SELinux (file/access)  │  ← Mandatory access control
├────────────────────────────────────┤
│  Linux Kernel (syscall dispatch)   │
└────────────────────────────────────┘
```

### When a File Write Occurs

1. **AppArmor**: Check if the process's profile allows writing to that path
2. **SELinux**: Check if the process type is allowed to write to the file type
3. **Capabilities**: Check if `DAC_OVERRIDE` or `DAC_READ_SEARCH` is needed
4. **Seccomp**: Check if the `write` or `pwrite64` syscall is allowed

### LSM Stacking

Modern kernels (5.0+) support stacking multiple LSMs. The typical stack is:

```
integrity (IMA/EVM) → SELinux → Smack → AppArmor → Yama
```

In practice, you cannot run both SELinux and AppArmor simultaneously — they are mutually exclusive LSMs. Choose one based on your distribution:
- **Ubuntu/Debian**: AppArmor
- **RHEL/CentOS/Fedora/Amazon Linux**: SELinux

## K8s SecurityContext Fields for AppArmor and SELinux

### AppArmor in Kubernetes (deprecated annotation → GA)

Kubernetes moved AppArmor from annotations to a field in 1.30:

```yaml
# Legacy approach (K8s < 1.30)
metadata:
  annotations:
    container.apparmor.security.beta.kubernetes.io/app: localhost/contnginx

# Modern approach (K8s 1.30+)
spec:
  containers:
  - name: app
    securityContext:
      appArmorProfile:
        type: Localhost
        localhostProfile: contnginx
```

AppArmor types:
- `RuntimeDefault`: Use the runtime's default profile
- `Localhost`: Use a profile loaded on the node
- `Unconfined`: No AppArmor (avoid)

### SELinux in Kubernetes

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: selinux-pod
spec:
  containers:
  - name: app
    image: nginx
    securityContext:
      seLinuxOptions:
        user: system_u
        role: system_r
        type: container_t
        level: s0:c123,c456
```

Kubernetes assigns an SELinux MCS label automatically when using a container runtime with SELinux support. Custom levels are useful for multi-tenancy isolation.

### Combined Security Context

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-pod
spec:
  securityContext:
    runAsUser: 10001
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
    seLinuxOptions:
      type: container_t
  containers:
  - name: app
    image: myapp
    securityContext:
      capabilities:
        drop: ["ALL"]
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
```

This combines every hardening technique: non-root user, seccomp default profile, SELinux type enforcement, no capabilities, no privilege escalation, and a read-only filesystem.

## Debugging LSM Issues

### AppArmor Denial

```bash
# Check system logs
sudo journalctl -f | grep apparmor
# Output: audit: type=1400 audit(12345.678:9): apparmor="DENIED" operation="open" profile="docker-default" name="/proc/1/mounts" pid=1234 comm="cat" requested_mask="r" denied_mask="r" fsuid=0 ouid=0

# Resolve: either add the path to a custom profile or adjust the app
```

### SELinux Denial

```bash
# Check audit logs
sudo ausearch -m avc --start recent
# Output: type=AVC msg=audit(12345.678:9): avc:  denied  { read } for  pid=1234 comm="httpd" name="index.html" dev="dm-0" ino=12345 scontext=system_u:system_r:container_t:s0:c1,c2 tcontext=unconfined_u:object_r:httpd_sys_content_t:s0 tclass=file

# Resolve with audit2allow
sudo audit2allow -a -M mypolicy
sudo semodule -i mypolicy.pp
```

## Interview Tips

Know the distribution binding: **AppArmor = Ubuntu/Debian, SELinux = RHEL/CentOS/Amazon Linux**. Understand that starting from scratch, seccomp + capabilities provides 80% of the value. AppArmor/SELinux add file-level MAC — important for multi-tenant environments where container isolation is critical. Be able to explain why `--privileged` disables all three mechanisms (capabilities, seccomp, and AppArmor/SELinux) and why that's dangerous. For a broader view of how these security mechanisms fit into the Docker runtime stack, see [Docker Architecture](../docker/docker-architecture.md).
