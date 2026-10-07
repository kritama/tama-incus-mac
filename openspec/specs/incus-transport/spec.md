# incus-transport Specification

## Purpose

Gives tama-machine a small outer-runtime control contract and transparent access to the canonical Incus API.

## Requirements

### Requirement: Local endpoints

The service SHALL expose owner-only Unix sockets at <state-dir>/runtime.sock and <state-dir>/incus.sock, defaulting to ~/.tama/incus-mac. Neither endpoint SHALL listen on TCP.

#### Scenario: Endpoint discovery

- **WHEN** tama-machine reads runtime status
- **THEN** it receives the Incus socket path and readiness state

### Requirement: Transparent proxy

Incus transport SHALL relay bytes bidirectionally over vsock to the guest Incus Unix socket without rewriting URLs, JSON, headers or WebSocket frames. Streaming and half-close SHALL be supported.

#### Scenario: Streaming exec

- **WHEN** Incus upgrades an exec or event connection to WebSocket
- **THEN** frames and connection lifetime are preserved across the bridge

### Requirement: Control API

The service SHALL implement GET status, capabilities, health, config and progress; POST create, start, stop and restart; PUT config; and DELETE runtime beneath /v1/runtime. Responses SHALL use versioned Codable JSON and stable error codes. Start SHALL accept an optional bounded remaining-time budget without changing saved configuration; an empty body SHALL retain existing behavior. Progress SHALL be read-only and independently readable during boot.

#### Scenario: Unknown route

- **WHEN** a client requests an unsupported control path
- **THEN** HTTP 404 is returned with a machine-readable error

#### Scenario: Progress during startup

- **WHEN** a client reads progress while another connection waits for start
- **THEN** it receives the current operation and provisioning phase without blocking on completion or reporting false readiness

#### Scenario: Remaining startup budget

- **WHEN** start receives a valid remaining-time budget
- **THEN** the daemon bounds the entire boot and expected restart by that budget and its configured readiness limit without persisting a resource or timeout update

#### Scenario: Invalid startup budget

- **WHEN** start receives an invalid, unbounded, or malformed budget payload
- **THEN** it returns a configuration/request error before booting or altering durable state

### Requirement: Bounded requests

Control HTTP SHALL bound header/body size, reject transfer encodings and ambiguous lengths, close after one response, and enforce idle timeouts. Proxy traffic MUST NOT be parsed as control HTTP.

#### Scenario: Ambiguous framing

- **WHEN** a request contains duplicate content-length headers
- **THEN** HTTP 400 is returned without executing the mutation

### Requirement: Host-only helper

Guest helper SHALL accept only host vsock CID 2 and expose the Incus Unix socket and a read-only health endpoint on distinct fixed ports. No helper endpoint SHALL accept guest shell commands.

#### Scenario: Guest peer denied

- **WHEN** a nested guest connects to the helper
- **THEN** the connection is rejected before any Incus bytes are relayed

### Requirement: Incus remains canonical

All instances, images, snapshots, profiles, projects, networks, storage, remotes and transfer/migration SHALL remain standard Incus operations. The runtime API MUST NOT introduce workload equivalents.

#### Scenario: Portable transfer

- **WHEN** tama-machine transfers an instance to another Incus host
- **THEN** it uses standard Incus APIs and artifacts without runtime-specific workload metadata

### Requirement: Relay availability

Host relay I/O SHALL use bounded buffers and nonblocking readiness notifications so idle streams cannot exhaust workers needed for control requests or health probes. Fatal failure of either guest listener SHALL terminate the helper for supervisor restart; transient accept errors SHALL be retried. Guest health SHALL require the Incus relay listener to have started.

#### Scenario: Idle streams

- **WHEN** many Incus streams remain idle or apply backpressure
- **THEN** control requests and health probes still complete, and duplex half-close remains supported

#### Scenario: Listener failure

- **WHEN** a guest listener fails permanently while another has active clients
- **THEN** the helper exits promptly and cannot continue advertising healthy transport

### Requirement: Complete configuration JSON

Create and replacement configuration requests SHALL include all nonoptional configuration fields. Swift initializer and generated template defaults SHALL NOT imply omitted-field defaults in JSON. The optional seed path MAY be omitted and share read_only SHALL default to true.

#### Scenario: Missing required fields

- **WHEN** a create body provides only an appliance manifest path
- **THEN** the service rejects the incomplete configuration with HTTP 400
