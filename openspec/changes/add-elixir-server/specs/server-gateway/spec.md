# Spec Delta

## Purpose

Gives local and remote Macus clients one authenticated public connection boundary while preserving the private native VM runtime and Incus protocols.

## ADDED Requirements

### Requirement: Public route contract

Macus SHALL expose /runtime, native discovery and /1.0/*, and one composed /mcp endpoint on its authenticated gateway. Shared compute code SHALL run embedded without its own endpoint or listener. The gateway MUST NOT require /incus aliases or modified clients; unknown paths SHALL return bounded failures.

#### Scenario: Native Incus paths

- **WHEN** an unmodified standard Incus client connects to the server
- **THEN** discovery, REST and WebSocket requests use native paths without a namespace rewrite or upstream client patch

#### Scenario: Public runtime path

- **WHEN** a client requests `/runtime/status` or deletes `/runtime` with explicit confirmation
- **THEN** the server uses the corresponding private `/v1/runtime` route without requiring a version in the public URL

### Requirement: Authenticated local and remote HTTPS

The server SHALL support HTTPS on loopback and explicitly configured LAN/remote addresses. The default SHALL be loopback-only. Cleartext public HTTP, automatic wildcard binding and automatic router/firewall changes MUST NOT be enabled. Endpoint discovery SHALL identify the selected state's advertised HTTPS address and trust identity.

#### Scenario: Remote listener enabled

- **WHEN** the owner configures a LAN bind address, advertised HTTPS URL and matching TLS identity
- **THEN** authenticated remote clients can reach the same runtime, Incus and MCP routes through that address

#### Scenario: Invalid remote configuration

- **WHEN** the advertised identity cannot be validated or the bind address is already occupied
- **THEN** startup fails explicitly without falling back to cleartext, another user's listener or a silently different public endpoint

### Requirement: Authentication before private transport access

Except for bounded discovery and explicit certificate enrollment, native Incus requests SHALL require an enrolled TLS client certificate. Runtime and MCP requests SHALL require valid scoped per-user bearer credentials. Authorization SHALL occur before privileged backend access and upgrades. Anonymous discovery SHALL reveal only gateway identity and protocol information, never runtime configuration or guest data.

#### Scenario: Untrusted local client

- **WHEN** a client on localhost presents an untrusted certificate or invalid bearer token
- **THEN** the request is denied and no privileged request reaches either Swift socket

#### Scenario: Unauthorized upgrade

- **WHEN** an unauthenticated caller requests an Incus WebSocket upgrade
- **THEN** the server denies the handshake before opening an upstream connection

#### Scenario: Insufficient scope

- **WHEN** a read credential requests a runtime mutation or workload mutation
- **THEN** access is denied before dispatch with a stable permission failure

### Requirement: Gateway credential lifecycle

The owner SHALL be able to enroll and revoke client certificates and issue and revoke scoped bearer credentials without modifying workload data. Credential material SHALL remain owner-private outside installed packages. Guest certificate enrollment MUST NOT grant gateway access implicitly. Revocation SHALL prevent new requests and close associated long-lived streams within a documented bound.

#### Scenario: Certificate revoked

- **WHEN** the owner revokes an enrolled Incus client certificate
- **THEN** subsequent HTTP and upgrade requests fail and its active gateway streams close within the configured revocation interval

#### Scenario: Private material retained

- **WHEN** the package is upgraded or uninstalled
- **THEN** private keys and trust metadata are preserved outside the package, are absent from logs and normal JSON output, and are not regenerated silently

### Requirement: Single-use certificate enrollment

Certificate enrollment by a client not yet trusted SHALL require a valid expiring single-use gateway enrollment token and proof of the presented certificate's private key. Enrollment SHALL update only gateway trust and MUST NOT open a guest stream. Consumed, expired or invalid tokens SHALL fail without granting access. Administrative trust operations SHALL require an enrolled owner-admin identity.

#### Scenario: Native client enrollment

- **WHEN** a standard Incus client presents a valid enrollment token and its certificate
- **THEN** the gateway records that certificate exactly once using native enrollment response shapes and subsequent authenticated requests can use it

#### Scenario: Enrollment token replay

- **WHEN** a second client reuses a consumed or expired enrollment token
- **THEN** enrollment is denied before any privileged backend access or additional certificate trust is committed

### Requirement: Native Incus payload and identity handling

The gateway SHALL preserve workload paths, queries, bodies, status codes, operation handles, ETags and streaming semantics. HTTP hop-by-hop handling and explicitly documented gateway TLS identity, advertised-address and certificate-trust metadata SHALL be the only exceptions. Generic workload response rewriting and guest-network endpoint advertisement MUST NOT be used to implement gateway identity.

#### Scenario: Conditional update

- **WHEN** a standard client sends a project-scoped request with an If-Match header
- **THEN** Incus receives that query and condition and its conflict or success response is preserved

#### Scenario: Transport identity

- **WHEN** a standard client inspects server identity or manages gateway client trust
- **THEN** the response represents the public gateway TLS identity and trust store, and guest-internal certificates or addresses cannot redirect the client around the gateway

### Requirement: Bounded streaming and protocol upgrades

The gateway SHALL support streaming request/response bodies, Incus WebSocket exec, console and events, and other native upgrade streams. It SHALL preserve binary data, protocol control messages, applicable half-close and disconnect behavior. Buffers and concurrent streams SHALL be bounded; idle streams MUST NOT starve runtime or health requests.

#### Scenario: Interactive command

- **WHEN** a standard client attaches stdin, terminal output and control streams to a guest command
- **THEN** data and terminal control pass through the gateway without Phoenix-specific framing or whole-stream buffering

#### Scenario: Slow consumer

- **WHEN** a client stops consuming a long-lived stream
- **THEN** backpressure is bounded and unrelated authenticated status requests remain responsive

### Requirement: Availability and failure isolation

Server availability SHALL be distinguishable from VM and Incus readiness. The server SHALL remain usable for authorized runtime inspection while the guest is absent, stopped, booting or failed. Server restart MUST NOT stop the VM. Backend loss SHALL produce explicit bounded failures and SHALL NOT automatically replay potentially accepted mutations.

#### Scenario: Guest stopped

- **WHEN** the guest is stopped while the gateway is running
- **THEN** runtime status and start remain available and workload requests report unavailable rather than claiming readiness

#### Scenario: Server restart

- **WHEN** the server process crashes and its supervisor restarts it
- **THEN** Swift retains VM ownership, the VM is not restarted or deleted, and new requests reconnect to the existing private endpoints

### Requirement: Separate body handling

MCP and transparent Incus requests SHALL retain their required body handling and MUST NOT pass through a common JSON decoder that consumes or changes their bytes. Runtime requests SHALL retain their own bounded framing and configuration validation. Incus traffic MUST NOT inherit the private control API's single-request or body-size restrictions.

#### Scenario: Binary upload

- **WHEN** an Incus client uploads a binary image larger than the runtime request limit
- **THEN** the gateway streams the upload to Incus without decoding it as JSON or applying the runtime body limit

### Requirement: Public connection ownership

The published client contract SHALL identify the gateway as the normal connection point. Runtime responses SHALL identify the public endpoint and readiness without directing clients to private Swift socket paths. The private sockets SHALL remain same-user implementation transports rather than a separately advertised client service.

#### Scenario: Endpoint discovery

- **WHEN** a client reads public runtime status
- **THEN** it receives public connection information and independently reported server/runtime readiness without backend credentials or socket paths

### Requirement: Listener-free shared service embedding

The gateway SHALL embed the shared compute application in its existing server process with that dependency's endpoint supervision disabled. Ambient PHX_SERVER or PORT settings MUST NOT enable another listener. Public routing and gateway identity SHALL remain Macus-owned.

#### Scenario: Embedded application startup

- **WHEN** Macus starts with configured shared workers and ambient server environment variables
- **THEN** only the Macus public endpoint starts and no dependency-owned endpoint process or port is opened

### Requirement: One configured local target per Macus endpoint

The composed endpoint SHALL use Macus's registered runtime and Incus backend. Arbitrary request addresses SHALL not select independent hosts. Gateway restart or shared worker restart MUST NOT start, stop or delete the Swift VM or its workloads implicitly.

#### Scenario: Shared worker recovery

- **WHEN** embedded shared workers restart while Swift owns a ready VM
- **THEN** the same VM and workload state remain available through the existing private transports

### Requirement: Optional outbound central connector

Macus SHALL run an explicitly enrolled connector in its existing Elixir service, with no extra endpoint, inbound port, repository or launchd job. Device and central identities SHALL be verified before dispatch. Central outages MUST NOT prevent standalone local runtime, native Incus or MCP access.

#### Scenario: Central connection unavailable

- **WHEN** the enrolled connector cannot reach central
- **THEN** the gateway reports disconnected status while local services and Swift-owned workloads remain available

### Requirement: Constrained delegated execution

Connected dispatch SHALL match active target/generation, known operation version and approved local scopes/projects. External owner context SHALL remain distinct from local owner authority. Arbitrary commands, destinations, modules and credential administration MUST NOT be accepted through the connector.

#### Scenario: Local permission denied

- **WHEN** central requests an operation outside the installation's approved capabilities
- **THEN** Macus rejects it before private socket or host runtime access even if the central user otherwise has a grant
