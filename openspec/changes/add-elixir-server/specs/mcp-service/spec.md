# Spec Delta

## Purpose

Composes portable Opsmaru compute tools with Macus runtime tools through one authenticated MCP endpoint while sharing caller-bound execution and retaining macOS runtime safety.

## ADDED Requirements

### Requirement: Maintained MCP protocol integration

Macus SHALL expose one /mcp endpoint composing shared compute tools with Macus-owned runtime tools through the maintained protocol implementation. Embedded shared services MUST NOT start another endpoint. Unsupported protocol/transport features MUST NOT be advertised, and authentication SHALL precede discovery and execution.

#### Scenario: Unsupported protocol

- **WHEN** a client requests a protocol version or feature unsupported by the pinned dependency
- **THEN** the server returns the dependency's bounded protocol failure rather than inventing compatibility

### Requirement: Scoped inspection and mutation tools

Macus runtime tools and shared native Incus tools SHALL enforce read, write, exec and destructive scopes during discovery and execution. Shared tool names/schemas/results SHALL match their library contract. Unknown or forbidden tools SHALL fail before backend/provider access; no unrestricted host command tool SHALL exist.

#### Scenario: Read-only identity

- **WHEN** an authenticated identity has only inspection scopes
- **THEN** it can discover and execute authorized inspection tools but cannot discover or execute mutation tools

#### Scenario: Canonical workload mutation

- **WHEN** an authorized tool creates, changes, snapshots or deletes an Incus workload
- **THEN** it delegates to the native Incus client and returns standard operation identity without creating a second workload manager

### Requirement: Explicit destructive inputs

Runtime deletion, workload deletion, destructive restore and forced stop SHALL require explicit destructive input and permission. Runtime deletion SHALL retain the private API's stopped-state and confirmation requirements. Broad deletion based on inferred consent or unvalidated model text MUST NOT occur.

#### Scenario: Missing confirmation

- **WHEN** a deletion tool lacks its required explicit confirmation
- **THEN** validation rejects it before any guest or runtime mutation

### Requirement: Truthful asynchronous tool behavior

Long-running shared and runtime tools SHALL use the same configured shared store/runner or explicitly identify native acceptance. Durable task advertisement SHALL require complete library contracts and consumer recovery evidence. In-memory handles and accepted operations MUST NOT be described as durable or completed work.

#### Scenario: Durable handoff

- **WHEN** a tool returns a durable MCP task handle
- **THEN** the owner-bound task and accepted execution intent are durable before the response and subsequent task lookup can recover them after server restart

#### Scenario: Lost mutation response

- **WHEN** the server cannot determine whether a mutation was accepted before a connection failed
- **THEN** it records an explicit uncertain outcome and does not automatically issue the mutation again

### Requirement: Task ownership and stream reconciliation

Task lookup, updates and cancellation SHALL be bound to the authenticated owner. Cancellation intent and state transitions SHALL be durable and idempotent. Task notifications SHALL occur after commit; bounded subscription streams SHALL reauthorize and close on expiry, revocation or overflow. Polling SHALL remain authoritative after notification loss.

#### Scenario: Another owner's task

- **WHEN** an identity requests a task owned by another identity
- **THEN** the server returns an owner-safe failure without disclosing or modifying that task

#### Scenario: Notification interruption

- **WHEN** a task subscription disconnects or overflows
- **THEN** the client can reconcile committed task state by owner-bound lookup without a fabricated replay guarantee

### Requirement: Bounded results and execution

Tool inputs, outputs, concurrency, deadlines and subscription queues SHALL have documented bounds. Exec tools SHALL run only inside an explicitly selected Incus instance and bound captured output. Tool errors SHALL preserve useful native codes without revealing credentials, private host files or unrestricted guest logs.

#### Scenario: Output limit reached

- **WHEN** a command produces more output than a tool's declared capture limit
- **THEN** the result identifies truncation or the bounded failure and the server remains responsive to other clients

### Requirement: Protocol and backend acceptance

MCP acceptance SHALL exercise the dependency's applicable conformance fixtures plus Macus tool schemas, scope checks, explicit confirmations and task recovery. Mock protocol success SHALL remain distinct from actual runtime and guest workload acceptance.

#### Scenario: Conformance without guest

- **WHEN** MCP fixture tests pass against fake runtime and Incus endpoints
- **THEN** protocol evidence is recorded and hardware-backed mutation acceptance remains incomplete

### Requirement: Shared and host catalogue composition

Macus SHALL register shared tool modules and its runtime extensions in one catalogue. Duplicate tool names SHALL fail construction. The library's standalone Linux catalogue MUST NOT be required for runtime calls or start inside Macus.

#### Scenario: Combined discovery

- **WHEN** an authorized caller discovers tools at the Macus endpoint
- **THEN** allowed shared compute and Macus runtime tools appear together with one authentication and task-ownership boundary

### Requirement: Trusted host and owner binding

Macus SHALL supply the shared service with verified principal, owner key, scopes and registered backend/provider identity. Those bindings SHALL survive asynchronous execution. Caller-selected URLs, forged owner fields and unregistered host providers MUST NOT override trusted configuration.

#### Scenario: Forged backend selection

- **WHEN** a tool request supplies another owner or unregistered backend address
- **THEN** no shared or host operation is dispatched using that forged binding

### Requirement: Host-specific runtime capabilities

Macus SHALL supply its runtime capability and path-prerequisite provider without transferring VM ownership to shared code. Capability inspection SHALL be passive; share changes requiring a stopped VM MUST NOT trigger an implicit restart or claim readiness.

#### Scenario: Unavailable workspace share

- **WHEN** host path inspection discovers a new share would require stopped-runtime configuration
- **THEN** it reports that prerequisite without changing sharing or restarting the VM

### Requirement: Local and delegated target identity

Local tools SHALL use only Macus's configured target, permitting omitted target ID locally and rejecting a different target. Central calls SHALL carry the exact enrolled target/generation and a distinct delegated owner binding. Remote execution SHALL retain shared schemas and Macus lifecycle/destructive-input policy.

#### Scenario: Delegated lifecycle safety

- **WHEN** central requests a Macus share configuration change while the VM is running
- **THEN** the same stopped-runtime prerequisite applies and the connector does not restart the VM implicitly

### Requirement: Central receipt recovery

Connected dispatch SHALL commit stable dispatch ID/input digest/owner/target binding in the existing shared journal before acknowledgement. Duplicate matching dispatch SHALL return its receipt; conflicting input SHALL fail. Local and delegated tasks SHALL remain isolated, with native uncertainty preserved through reconnect.

#### Scenario: Duplicate central dispatch

- **WHEN** central resends a dispatch whose acknowledgement was lost
- **THEN** Macus returns the recorded receipt/native outcome without starting another mutation or runner
