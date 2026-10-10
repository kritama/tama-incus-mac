# Spec Delta

## Purpose

Provides Macus consumers with the shared portable Opsmaru Incus client through the existing native bridge, preserving upstream-traceable behavior and independent consumer acceptance.

## ADDED Requirements

### Requirement: Pinned API and behavior coverage

Macus SHALL consume an immutable shared-client dependency with a pinned upstream method/type inventory, typed operations and native errors. It MUST NOT implement a duplicate portable client. Missing dependency parity SHALL remain visible and block a complete-port claim; raw proxy coverage MUST NOT substitute for typed-client evidence.

#### Scenario: Public method coverage

- **WHEN** the port is reviewed for completion
- **THEN** each public operation and model in the pinned inventory maps to an implemented Elixir equivalent and verification evidence, with any unsupported entry explicitly preventing full parity acceptance

### Requirement: Canonical Incus transport

The shared client SHALL use Macus's explicitly configured native Incus socket and authenticated HTTPS identities where applicable. It SHALL preserve project/target parameters, extensions, ETags and native models. It MUST NOT start another bridge, invoke a host VM CLI or depend on a separate shared-service listener.

#### Scenario: Same local bridge

- **WHEN** an MCP tool requests an Incus operation
- **THEN** the client uses the existing `incus.sock` bridge and the guest Incus API, without a Swift FFI layer or another host-to-guest bridge

#### Scenario: Unsupported extension

- **WHEN** a requested client operation requires an extension absent from the selected server
- **THEN** the client returns a truthful compatibility failure before using an unsupported protocol

### Requirement: Operation completion and cancellation

Asynchronous Incus acceptance SHALL return an operation handle distinct from completion. Waiting, polling, progress and supported cancellation SHALL preserve native semantics and explicit deadlines. A local timeout or disconnect MUST NOT be presented as successful remote cancellation. Potentially accepted mutations MUST NOT be retried automatically.

#### Scenario: Accepted create

- **WHEN** Incus accepts instance creation as a background operation
- **THEN** the client reports acceptance with the native handle and reports success only after observing its final successful state

#### Scenario: Wait deadline

- **WHEN** the caller's waiting deadline expires
- **THEN** the client returns timeout with available operation identity and does not assert that the guest operation stopped

### Requirement: Event concurrency and resource bounds

Event subscriptions, callbacks and streams SHALL have explicit lifetime, cancellation and resource bounds. An overloaded event consumer SHALL fail visibly rather than silently lose events or accumulate an unbounded queue. Disconnect and completion races SHALL release client resources without affecting other operations.

#### Scenario: Event backlog

- **WHEN** an event consumer exceeds its configured queue bound
- **THEN** its subscription terminates with an explicit overflow error and the caller can reconcile authoritative operation state

### Requirement: Streaming behavior parity

The client SHALL preserve the pinned SDK's exec, console, event, file, image, backup and migration transport behavior, including native binary/upgrade channels where applicable. HTTP streaming MUST NOT be assumed to be WebSocket-only. Capability limits of a guest SHALL remain distinct from missing client implementation.

#### Scenario: Command control

- **WHEN** a guest command receives streamed input and terminal-control messages
- **THEN** the client delivers native channel data and correctly observes output, exit status and cleanup

### Requirement: Independently verified maintenance

Macus SHALL retain shared dependency/upstream provenance and link its library behavior evidence separately from consumer bridge, identity and real-guest acceptance. Dependency updates SHALL expose changed inventory entries and rerun affected consumer checks. Library fixture success MUST NOT complete Macus hardware acceptance.

#### Scenario: Upstream update

- **WHEN** the upstream revision changes
- **THEN** the coverage inventory exposes added or changed methods and models before the new version is described as fully supported

### Requirement: Shared dependency without sibling checkout

CI and installed Macus builds SHALL resolve the shared client through an immutable revision or released package and lockfile. An editable sibling path SHALL be development-only. Missing shared support MUST NOT trigger a Macus-only fallback implementation.

#### Scenario: Missing dependency method

- **WHEN** the selected shared dependency lacks a required client operation
- **THEN** integration reports missing support and leaves its acceptance incomplete without implementing a duplicate method
