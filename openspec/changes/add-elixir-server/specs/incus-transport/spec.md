# Spec Delta

## MODIFIED Requirements

### Requirement: Local endpoints

The Swift runtime SHALL retain owner-only Unix sockets at <state-dir>/runtime.sock and <state-dir>/incus.sock, defaulting to ~/.tama/incus-mac. Neither private endpoint SHALL listen on TCP. The Elixir server SHALL be the normal client connection boundary; public endpoint discovery SHALL advertise its HTTPS endpoint rather than private socket paths.

#### Scenario: Endpoint discovery

- **WHEN** tama-machine reads runtime status
- **THEN** it receives the public server endpoint and separate server/runtime readiness; private Swift status retains its internal Incus socket path

### Requirement: Transparent proxy

The private Swift Incus transport SHALL relay bytes bidirectionally over vsock to the guest Incus Unix socket without rewriting URLs, JSON, headers or WebSocket frames. Streaming and half-close SHALL be supported. Public gateway identity/trust handling SHALL remain outside this byte relay.

#### Scenario: Streaming exec

- **WHEN** Incus upgrades an exec or event connection to WebSocket
- **THEN** frames and connection lifetime are preserved across the bridge

#### Scenario: Public gateway preserves the native bridge

- **WHEN** an authenticated request arrives at the public Incus endpoint
- **THEN** the gateway forwards it through incus.sock and the existing native vsock relay without requiring another host-to-guest bridge; gateway identity and trust mediation are restricted to the server-gateway contract

### Requirement: Control API

The private Swift service SHALL implement GET status, capabilities, health, config and progress; POST create, start, stop and restart; PUT config; and DELETE runtime beneath /v1/runtime. Responses SHALL use versioned Codable JSON and stable error codes. Start SHALL accept an optional bounded remaining-time budget without changing saved configuration; an empty body SHALL retain existing behavior. Progress SHALL be read-only and independently readable during boot.

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

#### Scenario: Public runtime mapping

- **WHEN** an authenticated client uses /runtime or /runtime/*
- **THEN** the gateway maps the allowlisted method and path to the equivalent private /v1/runtime route while retaining its errors, conflict rules and original request budget

## ADDED Requirements

### Requirement: Shared client bridge reuse

Shared compute operations SHALL use the explicitly configured existing incus.sock transport. The typed shared client and native gateway proxy SHALL remain separate consumers of that bridge without another guest helper, Swift FFI layer or dependency-owned listener.

#### Scenario: Shared inspection through Macus

- **WHEN** a composed shared tool inspects an Incus instance
- **THEN** its library client uses the same native relay as the gateway and no additional host-to-guest bridge is created

### Requirement: Connected operation bridge reuse

Enrolled central operations SHALL reuse the existing native Incus relay and private Swift runtime adapter after delegated authorization. The connector MUST NOT add another guest helper, expose private socket paths publicly or bypass native stream/lifecycle limits.

#### Scenario: Central workload inspection

- **WHEN** a permitted central operation inspects this Macus target
- **THEN** the same configured incus.sock client is used and no new host-to-guest transport is created
