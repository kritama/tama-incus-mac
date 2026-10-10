# Tasks

Planning revision only. Implementation continues only on a later apply request. The seven checked tasks below record original scaffold/reference/transport evidence; they do not establish the new Opsmaru dependency or embedded behavior. Opsmaru's separate `add-embedded-incus-foundation` owns library startup/client implementation first; `add-compute-substrate` owns later tools/tasks/connectors. Local server/typed-client integration does not wait for central features. Gate dependent work on an actual implemented immutable revision, not a placeholder package. Macus gateway/runtime/proxy work remains consumer-owned and can proceed after this revised plan is validated.

## 1. Headless project and embedded dependency integration

- [x] 1.1 Scaffold `server/` as a headless Phoenix/Cowboy app `:macus` with `Macus`/`MacusWeb`; verify Mix compilation, baseline tests and absence of HTML/assets/LiveView/Ecto scaffolding and nested generated AGENTS instructions.
- [x] 1.2 Pin compatible Elixir/OTP and released server dependencies in root mise plus `server/mix.lock`; verify dependency resolution and a clean-server build without absolute sibling path dependencies.
- [x] 1.3 Add the runtime/incus/proxy/auth/mcp module boundaries, runtime configuration and ignores for build/dependency outputs; verify fixture-only application startup and Git's ignored-path behavior.
- [x] 1.4 Reconcile `openspec/config.yaml`, development instructions and architecture docs with the approved dual-service scope and integrated Homebrew baseline; verify strict spec validation and documented root/server commands.
- [x] 1.5 Prove the Cowboy adapter choice using isolated TLS-to-Unix fixtures and the pinned official Incus client; verify native SFTP/NBD handshakes, coalesced bytes, binary duplex traffic, backend half-close, authorization before backend access, cleanup, Phoenix coexistence and response-header rejection without claiming production proxy or hardware acceptance.
- [ ] 1.6 Pin a real implemented add-embedded-incus-foundation Opsmaru revision or released package and resolve compatible locked dependencies; verify a clean build without the sibling checkout, no fabricated package/version and recorded distinct Opsmaru provenance.
- [ ] 1.7 Configure the foundational library embedded mode, explicit private backend/context and safe optional client workers before dependency startup; verify no Opsmaru endpoint/Repo/listener or third service starts even with PHX_SERVER/PORT present, client work waits for trusted host readiness and restart retains the Swift runtime marker without central/MCP/task prerequisites.
- [ ] 1.8 Reconcile root context/development/architecture docs and source module ownership with this revision; verify they identify Macus gateway/runtime/proxy versus Opsmaru client/MCP/tasks and canonical checks retain the original hardware boundary.

## 2. Reference provenance and shared coverage verification

- [x] 2.1 Pin the official Incus Go client source revision and generate the complete public method/type inventory with source provenance/notices; verify reproducible inventory generation and a diff that reveals an added or removed reference entry.
- [x] 2.2 Build reusable fake Unix/TLS Incus endpoints and differential request/response fixtures against the pinned reference; verify body, query, status/error and ETag mismatches are detected.
- [ ] 2.3 Bind to Opsmaru's typed codecs/version checks and transfer or reference reusable fixtures with notices while retaining Macus relay evidence; verify required/optional/null data and native error behavior at the actual pinned dependency revision without implementing duplicate codecs.
- [ ] 2.4 Document shared-library coverage/updates and consumer evidence ownership; verify the dependency's method/type manifest exposes missing entries, complete-port claims fail without full evidence and proxy fixtures are never substituted.

## 3. HTTPS, credentials and native trust mediation

- [ ] 3.1 Implement private gateway configuration, keys and atomic endpoint/build metadata with owner/path checks; verify unsafe ancestry, foreign ownership, missing/mismatched revisions and occupied ports fail before backend access.
- [ ] 3.2 Configure loopback-default HTTPS plus explicit LAN bind/advertised identity, TLS 1.3 and optional peer-certificate collection; verify valid TLS connections, wrong server identity, cleartext rejection and no automatic wildcard/router/firewall changes.
- [ ] 3.3 Implement enrolled client-certificate authentication and scoped bearer verification before routing/upgrade; verify fake backend counters remain zero for invalid credentials, missing scopes and unauthorized upgrades.
- [ ] 3.4 Implement owner-local `macus server` configuration/trust/token administration and private issuance destinations; verify commands never modify VM disks, overwrite unrelated trust, print secrets in normal output or activate services implicitly.
- [ ] 3.5 Implement expiry, credential revocation and bounded active-stream invalidation; verify denied subsequent requests and stream closure within the documented bound using deterministic timers.
- [ ] 3.6 Implement the bounded anonymous identity responses, allowlisted public certificate/address metadata and native gateway certificate-trust API; verify standard Incus identity/trust wire shapes and that guest trust never grants gateway access.
- [ ] 3.7 Implement expiring single-use native enrollment tokens and explicit rejection of unsupported restricted-certificate policies; verify initial standard-client enrollment, replay/expiry rejection and no guest forwarding during enrollment.
- [ ] 3.8 Document local/remote HTTPS configuration, gateway trust versus guest trust and credential rotation; verify examples against isolated TLS fixtures and redact credentials from captured diagnostics.

## 4. Runtime adapter and public routing

- [ ] 4.1 Implement the private runtime Unix HTTP client with existing request/response limits and timeout behavior; verify all lifecycle/config/status/health/progress methods against fake Swift endpoints.
- [ ] 4.2 Map the public `/runtime` methods to private `/v1/runtime` routes and project public status/endpoint metadata; verify DELETE root mapping, complete configuration validation, conflict codes, budget forwarding and omission of backend paths/secrets.
- [ ] 4.3 Mount route-specific body handling and authenticated health/readiness responses with Opsmaru embedded; verify MCP/Incus bodies bypass blanket parsing and gateway availability remains distinct from guest/shared backend readiness.
- [ ] 4.4 Document public/private APIs and Macus host provider capability/path prerequisites; verify fixture examples, no implicit share change/runtime restart and the stopped-VM configuration constraint remains visible.

## 5. Transparent Incus proxy and native client compatibility

- [ ] 5.1 Implement the bounded HTTP relay over incus.sock with queries, ETags, statuses, native errors and hop-by-hop handling; verify binary request/response streaming and gateway identity/trust exceptions against fixtures.
- [ ] 5.2 Implement WebSocket exec/console/events relay with native control/data frames; verify protocol upgrades, duplex traffic, backpressure, close and revocation behavior.
- [ ] 5.3 Implement quotas, idle/deadline controls and per-connection workers; verify idle/saturated streams do not starve auth/runtime/health and failed connections release resources.
- [ ] 5.4 Implement production native SFTP/NBD upgrades using the successful Cowboy protocol-switch trial; verify native handshakes/coalesced bytes, binary duplex traffic, half-close, auth-before-connect, revocation and production cleanup with the official client.
- [ ] 5.5 Preserve transport compatibility and documented identity/advertised-address mediation; verify native client connections remain at the public gateway rather than guest/private addresses.
- [ ] 5.6 Run unmodified standard Incus client fixtures for discovery, list, certificate trust and upgrade URL handling; verify failures distinguish proxy/CLI compatibility from shared typed-client coverage.
- [ ] 5.7 Document stream limits, native paths and gateway identity exceptions; verify the exercised route inventory has no /incus alias, upstream client patch or dependency-owned second listener.

## 6. Shared Incus client consumption and parity evidence

- [ ] 6.1 Configure the public Opsmaru client against the existing private relay and approved HTTPS identities; verify discovery, extension checks, deadlines and connection cleanup without a duplicate Macus client implementation.
- [ ] 6.2 Verify shared project/member selection, profiles and access/certificate operations at the pinned revision; compare relevant reference fixtures and retain Macus gateway trust mediation as a separate path.
- [ ] 6.3 Integrate shared instance create/read/update/state/delete methods; verify native accepted handles, errors, missing extensions and Macus backend binding.
- [ ] 6.4 Integrate shared snapshot/restore methods; verify native operation identity, conflicts and consumer destructive-input policy.
- [ ] 6.5 Integrate shared images/aliases/import/copy/export; verify streamed handoff, operation metadata and consumer identity/address behavior.
- [ ] 6.6 Verify shared network/cluster operations and configured native targeting; compare relevant inventory evidence without making Macus a multi-target controller; central registration remains in Opsmaru.
- [ ] 6.7 Verify shared storage/volume/snapshot/bucket operations; preserve native types/errors and link complete dependency evidence instead of reimplementing storage operations.
- [ ] 6.8 Verify shared file/backup/native-upgrade clients through Macus's bridge; exercise binary transfer, cleanup and the official-client reference independently of raw proxy success.
- [ ] 6.9 Integrate shared operation polling/waiting/cancellation and bounded events; verify local timeout versus remote cancellation, visible overflow and uncertain outcomes without replay.
- [ ] 6.10 Integrate shared exec/console/control streams; verify exit status, terminal controls, bounded capture and resource cleanup through the consumer bridge.
- [ ] 6.11 Verify shared migration/copy negotiation and remaining reference entries; retain reachable gateway-address selection and no guest-address policy bypass.
- [ ] 6.12 Validate the pinned dependency's complete method/type manifest and update consumer API documentation; verify every supported entry has independent evidence and missing library support blocks completion rather than falling back to Macus-only methods.

## 7. Later shared MCP transport, authorization and named tools

This group depends on add-compute-substrate tool/task contracts, not completion of the central service; it does not gate the first embedding/client milestone.

- [ ] 7.1 Mount maintained TamaMCP transport at Macus /mcp with Opsmaru cache/store/runner and Macus credential verification; verify supported conformance, one endpoint, bounded bodies and listener-free embedded dependency startup.
- [ ] 7.2 Implement/register Macus-owned runtime inspection/lifecycle/config tools and its host provider; verify Swift-equivalent behavior, stopped-state/confirmation rules and denial before provider/backend dispatch.
- [ ] 7.3 Register Opsmaru's shared native Incus inspection tools and host capability contract; verify shared names/schemas, trusted project/backend binding and authorized visibility.
- [ ] 7.4 Register shared mutation/guest-exec tools; verify native client delegation, acceptance versus completion, bounded results and no unrestricted host execution.
- [ ] 7.5 Enforce shared destructive scopes/inputs and Macus runtime-specific safety; verify wrong scopes, missing confirmation and forged owner/backend values cannot mutate a backend.
- [ ] 7.6 Publish the combined portable/runtime tool manifest and composition guide; verify duplicate-name compilation fails, shared schemas match the library and unsupported protocol/resource/stdin features remain absent.

## 8. Shared durable execution integration

- [ ] 8.1 Configure one Opsmaru journal/store/runner tree in private Macus-selected state; verify owner-bound lookup, path isolation, flush-before-handle and no credentials/closures or duplicate task tree in persisted execution.
- [ ] 8.2 Integrate registered shared and Macus-runtime execution descriptors/native operation IDs; verify restart recovery and uncertainty without replay across the consumer's crash boundaries.
- [ ] 8.3 Verify shared durable input/cancellation/deadline/output behavior with Macus identities and host adapter; confirm no-op updates do not resignal workers and local cancellation is not claimed as remote completion.
- [ ] 8.4 Integrate shared post-commit notifications with gateway expiry/revocation; verify overflow/lost delivery, owner isolation and authoritative polling using the maintained conformance contracts.
- [ ] 8.5 Gate task advertisement on both library contracts and Macus consumer recovery tests; document shared journal compatibility, rejected tool/provider descriptors and native acceptance distinctions without implementing another task engine.

## 9. Swift CLI and coordinated service startup

- [ ] 9.1 Add public HTTPS transport and private endpoint/credential discovery to normal Swift runtime/doctor/setup requests; verify total deadlines, pinned identity, response bounds and no fallback to backend sockets.
- [ ] 9.2 Extend service identity checks for the same separate Swift/Elixir jobs, stable launcher/ERTS paths and isolated state suffixes; verify actual-program conflicts, foreground reuse and no Opsmaru launchd job.
- [ ] 9.3 Extend preflight/serialized startup to validate paired Macus artifacts, pinned Opsmaru payload, embedded mode and public TLS configuration within one budget; verify invalid/missing payload cannot cause a second listener, startup fetch or guest mutation.
- [ ] 9.4 Route creation/boot/progress/live health through the gateway while preserving expected-reboot/cancellation behavior; verify gateway recovery and shared worker restart leave a ready VM running.
- [ ] 9.5 Change client setup to verified HTTPS registration and gateway enrollment using standard Incus commands; verify isolated INCUS_CONF, idempotence, explicit legacy conflict and default changes only with --set-default.
- [ ] 9.6 Report both service identities, public endpoint and truthful partial success without changing output contracts; verify JSON/progress/error fixtures and interruption restoration with only the established service pair.
- [ ] 9.7 Update CLI/API startup and transition documentation; verify embedded Opsmaru needs no separate install or activation and read-only requests remain passive.

## 10. Combined Mix release and package delivery

- [ ] 10.1 Configure the macus release with bundled ERTS, embedded Opsmaru, distribution disabled and immutable Macus/dependency metadata; verify isolated boot without host Elixir/Erlang, no Opsmaru endpoint and server-only shutdown.
- [ ] 10.2 Extend source installation to stage/verify the Swift and complete Macus release artifacts; verify unsafe destinations, mismatched Macus identity and missing pinned dependency are rejected without activation.
- [ ] 10.3 Extend formula/candidate generation to include the shared dependency and full release; verify real contents/checksums, entitlement preservation and matched Macus revision plus distinct Opsmaru revision with existing candidate tests.
- [ ] 10.4 Extend installed verification for full ERTS/library payload, stable opt paths and passive installation; verify no third service or host toolchain requirement and retain source-fallback versus poured-bottle evidence.
- [ ] 10.5 Document stop/unload of the same two owned jobs, upgrade/rollback/removal and shared journal compatibility; verify package fixtures retain disks, credentials and task state and reject incompatible journal rollback without rewriting it.
- [ ] 10.6 Reconcile delivery with add-homebrew-tap and update provenance docs; verify no Opsmaru standalone Linux packaging or publication/hardware claim is introduced into Macus.

## 11. Canonical integration checks

- [ ] 11.1 Extend canonical root checks and macOS CI for pinned Mix format/compile/tests, composed MCP and embedded release smoke checks alongside strict Swift checks; verify a clean checkout without the Opsmaru sibling passes fixture-only gates.
- [ ] 11.2 Run cross-component TLS/Unix fixtures with actual installed Swift/Macus processes and standard Incus CLI; verify runtime mapping, native upgrades, auth-before-backend, one public endpoint and partial-startup recovery.
- [ ] 11.3 Validate linked shared-client coverage and library conformance independently from consumer/proxy reports; verify exact library/reference revisions and no evidence class replaces another.
- [ ] 11.4 Run strict OpenSpec validation and review combined consumer/library boundaries; verify all deltas reconcile the embedding contract while unavailable hardware/remote gates remain unchecked.

## 12. Explicit installed-package hardware and remote acceptance

- [ ] 12.1 Extend opt-in acceptance for paired artifacts, pinned dependency, isolated state/credentials/client config and two service labels; verify no-opt-in invocation cannot start VZ or ordinary state.
- [ ] 12.2 With hardware opt-in, prove first/repeated macus start, public runtime control and native HTTPS Incus registration; verify embedded Opsmaru starts no endpoint/third service and retain package/guest evidence separately.
- [ ] 12.3 With hardware opt-in, prove native exec/console/events/binary transfers and composed shared/runtime MCP tools; verify denied credentials/scopes/confirmation cannot affect the guest.
- [ ] 12.4 With hardware opt-in, restart only Elixir and prove retained VM/workload/task identity; verify shared journal recovery/native operation reconciliation and no mutation replay.
- [ ] 12.5 With remote opt-in, use another client to prove TLS identity, native enrollment and scoped combined MCP/runtime access including revocation; record remote evidence separately from loopback and Linux acceptance.
- [ ] 12.6 With package/hardware opt-in, exercise the same two-job upgrade/rollback/removal preserving workloads/credentials/tasks; retain failed diagnostics and leave unavailable hardware/remote tasks incomplete.

## 13. Later optional central enrollment and connector integration

This group waits for the central/connector contracts in the later Opsmaru changes. It is independent of the first library/client integration and ordinary local startup.

- [ ] 13.1 Add Swift connect [url], connection status [--json] and disconnect commands plus owner-authenticated Elixir administration; verify usage/URL/state validation, saved-URL resume, changed-service conflict, output/deadline behavior and passive unregistered status with no secret output.
- [ ] 13.2 Reuse launchd/package identity preflight to explicitly recover only the matching Elixir job for connect; verify no Swift activation, downloads/appliance/VZ boot, share/native-remote changes or third service on absent/stopped runtime fixtures.
- [ ] 13.3 Integrate trusted central metadata and external-provider Device Authorization Grant through verified shared OAuth primitives; verify Keycloak browser approval, denied/expired/polling timeout and unsupported-provider failure without local issuer/password or persisted user tokens.
- [ ] 13.4 Implement private device generation, one-use key-bound enrollment and durable pending/completed receipt state; verify bad service/key/owner, unsafe paths, replay, lost completion response and idempotent same-registration recovery with no target duplication or private-key upload.
- [ ] 13.5 Enable shared outbound connector workers inside the existing server and configure central TLS/device/generation/local operation limits; verify no dependency endpoint/Repo/inbound port, backoff/restart, stale session fencing and separate connection/backend readiness.
- [ ] 13.6 Integrate delegated owner namespace and allowed operation descriptors with the same runtime/Incus adapters and journal runner; verify project/tool/target/owner/confirmation/stopped-state checks before socket access and inability to inspect local standalone tasks or run arbitrary host commands.
- [ ] 13.7 Integrate central task/dispatch receipt/native operation linkage and bounded control/data streams; verify duplicate/conflicting dispatch, missing acknowledgement, restart, interrupted exec/binary transfer, cancellation intent and uncertain outcomes cause no second mutation or runner.
- [ ] 13.8 Implement durable local disconnect, session closure and bounded central device revocation/reconciliation; verify offline revocation-pending, repeated disconnect, confirmed revoke/new generation and preserved local gateway/workload/receipt markers without automatic retry or VM shutdown.
- [ ] 13.9 Document and fixture-test standalone versus registered CLI/server/package behavior; verify no enrollment at install/start, central outage does not block local startup and disabled connectors remain disabled across upgrade/removal.
- [ ] 13.10 With explicit isolated installed/central/hardware opt-in, prove macus connect, central target discovery/authorized dispatch, receipt recovery and disconnect from a separate central client; retain device/OIDC/network evidence separately from VZ/guest tests and leave unavailable acceptance gates incomplete.
