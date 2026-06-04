---
title: "Docker Networking"
section: "Docker"
order: 35
---

# Docker Networking

Every running container needs a network stack — an interface, an IP, routes, and DNS. Docker's
libnetwork implements the Container Network Model (CNM) to manage these stacks. This article covers
the CNM building blocks, bridge modes, overlays, macvlan/ipvlan, DNS, inter-container
communication, and network security.

---

## CNM (Container Network Model)

CNM defines three abstractions:

- **Sandbox**: A container's network namespace, holding interfaces, routes, and DNS configuration.
- **Endpoint**: A veth pair connecting the sandbox to a network — one end in the container (`eth0`),
  the other plugged into the bridge.
- **Network**: A group of endpoints that can communicate directly — implemented as a Linux bridge or
  VXLAN tunnel.

Docker's **libnetwork** implements CNM with a pluggable driver model. `docker network create`
selects a driver (bridge, overlay, macvlan, ipvlan) which creates the corresponding kernel objects.
Third-party drivers (Calico, Weave, Flannel) register with libnetwork and provide alternative
backends.

---

## Default Bridge (docker0)

dockerd creates a Linux bridge named **docker0** at startup (default subnet 172.17.0.0/16).
Containers started without `--network` attach here.

Each container gets a **veth pair**: `eth0` lives in the container's netns, `vethXXXXX` is plugged
into docker0. Outbound traffic is SNATed via iptables MASQUERADE so container IPs reach the outside
world:

```bash
$ iptables -t nat -L -n
Chain POSTROUTING
MASQUERADE  all  --  172.17.0.0/16  0.0.0.0/0
```

`docker run -p 8080:80` adds a DNAT rule redirecting host port 8080 to the container's IP:80:

```bash
$ iptables -t nat -L DOCKER -n
DNAT       tcp  --  0.0.0.0/0  0.0.0.0/0  tcp dpt:8080 to:172.17.0.2:80
```

Docker also inserts FORWARD rules (ACCEPT for related/established and for the bridge subnet) and
uses `DOCKER-USER` / `DOCKER-ISOLATION` chains to preserve custom firewall rules across restarts.

**Limitations:** No DNS resolution by container name (requires deprecated `--link`), flat topology
with no isolation between groups.

---

## User-Defined Bridge

Created with `docker network create my-net`. Containers on the same user-defined bridge get:

- **DNS resolution by container name** — embedded DNS server at `127.0.0.11` resolves container
  names automatically. No `--link` needed.
- **Isolation** — each bridge is a separate L2 domain; containers on different bridges cannot
  communicate unless explicitly routed.
- **`--net-alias`** — containers can register alternative names for round-robin resolution.

```bash
docker network create my-net
docker run -d --name web --network my-net nginx
docker run -it --name client --network my-net alpine ping web  # resolves by name
```

Containers can attach to multiple networks via `docker network connect`, getting an interface on
each. This enables multi-tier patterns where the web tier is exposed but the database tier is
isolated.

---

## --network host

The container shares the host's network namespace — no veth pair, no netns, no NAT. The container
process binds directly to the host's IP and ports:

```bash
docker run --rm --network host nginx  # binds to host's port 80
```

**Benefits:** Zero overhead from bridge/veth copy, maximum throughput (5–15% improvement for
network-bound workloads).

**Risks:** Zero isolation — the container can bind any port, modify host network config, and (if
privileged) sniff traffic. Use only when performance is critical or the container manages the host's
network.

---

## --network none

Loopback only — no `eth0`, no external connectivity, no DNS:

```bash
docker run --rm --network none alpine ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
    inet 127.0.0.1/8 scope host lo
```

Used for security testing (prevent data exfiltration), offline batch jobs, and network diagnostics
in isolation.

---

## Overlay Networks (Swarm)

Overlay networks connect containers across hosts using **VXLAN** encapsulation (UDP 4789). Each
overlay gets a 24-bit VNI. When a container sends a packet to another host:

1. The frame reaches the local VTEP (Linux `vxlan` interface).
2. VXLAN header (VNI) + outer UDP header + destination host IP are prepended.
3. The remote VTEP decapsulates and delivers to the destination container.

```bash
docker swarm init
docker network create -d overlay my-overlay
docker service create --name web --network my-overlay nginx
```

The **docker_gwbridge** provides external NAT for overlay-attached containers. Encryption is
available with `--opt encrypted` (IPsec, ~10% CPU overhead). Swarm's routing mesh forwards
published ports on any node to a container on any node.

---

## macvlan / ipvlan

Containers get direct physical network access — no NAT, no docker0.

**macvlan:** Each container gets a unique MAC. The host interface runs in promiscuous mode. The
container appears as a directly connected device on the LAN:

```bash
docker network create -d macvlan --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 -o parent=eth0 my-macvlan
```

Limitations: host cannot reach container on same interface, switch MAC tables may be stressed.

**ipvlan L2:** All containers share the parent interface's MAC but get unique IPs. Avoids switch
MAC table pressure.

**ipvlan L3:** Containers on different subnets. The kernel routes between them. No promiscuous
mode, no broadcast overhead.

---

## DNS Resolution

Docker runs an embedded DNS resolver at `127.0.0.11` injected via `/etc/resolv.conf`:

- Queries a container name on the same user-defined network → returns that container's IP.
- Queries a Swarm service name → returns one or more replica IPs (round-robin).
- Queries an unknown name → forwarded to the host's upstream DNS.
- `--dns 8.8.8.8` overrides the upstream resolver.

```bash
$ docker run --rm alpine cat /etc/resolv.conf
nameserver 127.0.0.11
options ndots:0
```

---

## Container-to-Container Communication

- **Same bridge (L2):** Direct Ethernet forwarding between veth ports on the bridge. No iptables
  inspection on user-defined bridges.
- **Across bridges (L3):** Traffic must route through the host stack. Requires
  `net.ipv4.ip_forward=1`. Different bridges are isolated by default.
- **Across hosts:** Requires overlay, macvlan, or ipvlan. Default/user-defined bridges are
  single-host only.

The `DOCKER-USER` chain in iptables is preserved across Docker restarts — the correct place for
custom firewall policies:

```bash
iptables -I DOCKER-USER -p tcp --dport 80 -s 10.0.0.0/8 -j ACCEPT
iptables -I DOCKER-USER -p tcp --dport 80 -j DROP
```

---

## Network Security

- **Host mode** removes namespace isolation — never use in multi-tenant environments.
- **User-defined bridges** provide network-level isolation between groups. Use `--internal` to
  create bridges with no external egress.
- **`DOCKER-USER`** implements basic ingress/egress policy on a single host.
- **Multi-host policy** requires a CNI plugin (Calico, Cilium) or third-party libnetwork driver.
- **Swarm encryption** uses IPsec for overlay data when `--opt encrypted` is set.

---

## Strategic Analysis for Interview

### "How does Docker networking work under the hood?" (Core)

CNM → libnetwork → driver creates namespace, veth pair, bridge. Default bridge uses MASQUERADE +
DNAT. User-defined bridge adds DNS. Overlay adds VXLAN.

### "Default bridge vs. user-defined bridge?" (Comparison)

| Feature              | Default Bridge          | User-Defined Bridge     |
|----------------------|-------------------------|-------------------------|
| DNS by name          | No (needs --link)       | Yes                     |
| Isolation            | Single flat network     | Multiple isolated nets  |
| --net-alias          | No                      | Yes                     |
| Configuration        | None                    | Subnet, gateway, MTU    |

### "When to use --network host?" (Use case)

When container performance must match bare metal — proxies, packet processors, network tools.
Accepts zero isolation.

### "How do containers on different hosts communicate?" (Multi-host)

Overlay (VXLAN) or macvlan/ipvlan. Swarm creates the overlay automatically; standalone requires
`docker network create -d overlay`.

### "What is DOCKER-USER for?" (Firewall)

Preserving custom iptables rules across Docker restarts. Rules there are evaluated before Docker's
own FORWARD rules and are never overwritten.

---

## Cross-References

- [Docker Architecture](docker-architecture.md) — daemon stack that manages networks
  (dockerd → libnetwork → kernel).
- [Linux Capabilities](../container-image-hardening/linux-capabilities.md) — CAP_NET_RAW and CAP_NET_ADMIN
  control raw socket and interface manipulation inside containers.
- [Seccomp](../container-image-hardening/seccomp.md) — seccomp profiles restrict socket-related syscalls.
- [Read-only Filesystem](../container-image-hardening/readonly-filesystem.md) — combining RO root with network
  isolation for immutable container patterns.
- [SecurityContext vs PodSecurityContext](../kubernetes-security/securitycontext-vs-podsecuritycontext.md) —
  Kubernetes network-level security through NetworkPolicies and CNI plugins.
