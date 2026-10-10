# Architecture

The approved `add-elixir-server` change introduces this connection boundary:

```text
Swift CLI / standard Incus / MCP clients
                  │ HTTPS
           Phoenix / Cowboy (server/)
            /      │       \
     /runtime    /1.0*     /mcp (composed TamaMCP tools)
         │         │       │ Opsmaru.Incus + Macus runtime tools
   runtime.sock  incus.sock │
         │         │       │
   Swift VM actor  Swift duplex relay
         │         │
        VZ       virtio/vsock → guest Incus Unix socket
```

Swift owns the VM and disks. Macus Elixir code owns gateway identity/trust,
scoped bearer authorization, native HTTP/upgrade proxying and the private
Swift runtime adapter. Opsmaru owns the portable Incus client, shared MCP
tools and journal/store/runner implementation. It will run embedded in the
existing Macus BEAM, using private state beneath `<state-dir>/server`, with
its endpoint and Repo disabled. There is one public endpoint and the same
two independently supervised Swift/Elixir processes. The
public gateway defaults to loopback HTTPS; LAN binding and advertised identity
require explicit configuration. Authenticate before accessing either private
socket. Gateway certificate trust is independent of guest trust. Native Incus
paths, binary streaming and upgrades remain native, with only the documented
gateway identity/trust exceptions. Typed-client parity has separate upstream
inventory evidence; proxy breadth is not client-port evidence.

The first upstream milestone is `add-embedded-incus-foundation`: safe library
embedding and the native client. It must be adopted through a real implemented
immutable revision or released package. Later shared tools/tasks/connectors
are separate Opsmaru milestones and cannot gate this first local integration.
The current Macus lockfile does not include Opsmaru yet; no fallback client or
duplicate task engine is implemented here. Historical Macus reference inputs
can be transferred with notices, while Macus-specific bridge, identity and
runtime evidence remains in this repository.

The Macus-owned `Macus.Runtime.Client` now provides passive private Unix HTTP
requests to Swift, with native errors/budget payloads and bounded framing,
deadlines and socket ownership checks. It is independent of the shared Incus
client. The authenticated public routes are still pending implementation.

Optional explicit `macus connect [url]` will register only this selected Macus
target with central Opsmaru and enable an outbound connector inside the same
server. Central manages multiple targets; the local gateway uses only its
configured Swift/Incus backend. Local startup will remain usable without
enrollment or central availability. Disconnect will disable central dispatch
without stopping the VM or deleting workloads/credentials/task receipts.

One passive package will install Swift at `bin/macus` and a matching
bundled-ERTS Mix release at `libexec/macus`. `macus start` will activate both
per-user jobs inside the existing startup deadline. See the
[approved design](../openspec/changes/add-elixir-server/design.md).
Implementation progress is recorded in its tasks: the scaffold currently
starts without a listener, and the installed CLI/packaging still use the
Swift-only baseline below until their integration tasks are complete.

## Integrated Swift baseline

```text
macOS
  ├─ macus (this package) → runtime.sock lifecycle and standard incus CLI setup
  ├─ Unix HTTP runtime.sock → runtime actor → main-actor VZ controller
  └─ Unix stream incus.sock → duplex relay → VZ virtio socket
                                              ↓ host CID 2 only
                                       Alpine appliance (OpenRC)
                                         ├─ Incus Unix socket (vsock 8443)
                                         ├─ read-only health (vsock 8444)
                                         ├─ fresh ZFS tama-data/metadata or recognized legacy ext4
                                         └─ Incus workloads and portable artifacts
```

SwiftPM has one `Macus` library and one minimal `macus` executable dispatching daemon and client commands. Client code lives in `Sources/Macus/Client`; VM construction remains in the Virtualization area and is reached only through explicit serve mode. Instance operations stay in the standard Incus CLI. `Application` owns state and orchestration for the outer VM; `Virtualization` is the only area importing Apple's VZ framework. A protocol at that boundary permits deterministic tests. Configuration/status are Sendable value types. The runtime actor holds a mutation gate across awaits, so reentrancy cannot delete or reconfigure a starting machine. VZ objects remain on the main actor and its default main dispatch queue; blocking socket I/O runs on a concurrent GCD queue with immutable descriptor ownership. Stream relays use bounded buffers and preserve half-close and protocol upgrades.

EFI boots an ARM64 raw root disk. Alpine uses OpenRC/cloud-init and signed stable-branch APK packages. Storage mounts before Incus, and the host-CID-only helper starts after successful initialization. D-Bus, nftables, cgroup v2 and ARM64 QEMU/firmware are explicit guest dependencies. Virtio devices provide block storage, NAT, socket, entropy and explicit optional filesystem shares. Root is copied and expanded to at least 12 GiB. Fresh blank data disks become one ZFS pool, `tama-data`, with metadata at `/var/lib/incus` and workloads owned by Incus. Recognized ext4 disks keep directory storage. Unknown nonblank data is refused and readiness stays withheld.

VZ host capability detection controls nested virtualization. Live guest evidence controls Incus readiness, OCI (`instance_oci` extension) and VM (`/dev/kvm` plus enabled host nesting) availability. Incus itself owns inner QEMU/KVM, LXC, images, instances, storage, network bridges, profiles and migrations. The macOS process invokes no VM CLI. The guest helper has no shell-command endpoint.

The detailed decisions, rejected alternatives, normative requirements and recorded acceptance tasks are in [the OpenSpec change](../openspec/changes/archive/2026-10-04-native-incus-runtime/design.md). `macus start` acquires the pinned catalog image and may activate a per-user service. Automatic root-image upgrades, signed/notarized distribution, service forwarding, custom DNS, memory ballooning and sleep/resume policy remain future work. These features do not replace Incus workload operations.
