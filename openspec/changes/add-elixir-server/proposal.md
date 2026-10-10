# Proposal

## Why

Macus needs an authenticated public gateway for its Swift runtime, canonical Incus access and agent tools. Embedding the shared Opsmaru Phoenix application lets Macus provide those macOS integrations while reusing the same compute client, MCP tools and durable execution available in central Opsmaru and optional Linux connectors. Macus remains independently usable and can optionally register through an outbound connection to central Opsmaru.

## What Changes

- Keep one headless Phoenix/Cowboy Mix project in `server/`, OTP application `:macus` with `Macus`/`MacusWeb` namespaces, as Macus's public gateway.
- Depend on the separate `upmaru/opsmaru` Phoenix application `:opsmaru` in embedded mode. Configure its shared services inside the existing Macus BEAM with its endpoint/listener disabled; do not install another service or start an Opsmaru server process.
- Expose authenticated HTTPS for local and explicitly configured LAN/remote access. Retain gateway-owned certificate trust for standard Incus clients and scoped bearer credentials for `/runtime` and `/mcp` before private backend access.
- Expose `/runtime/*` mapped to Swift's private `/v1/runtime/*`; preserve `/` and native `/1.0/*` paths, HTTP/streaming/native upgrades and gateway identity mediation without `/incus` aliases or an upstream client patch.
- **BREAKING**: make the Macus gateway the normal connection boundary for Swift CLI and standard Incus clients. Keep `runtime.sock` and `incus.sock` internal and preserve existing remote conflict rules.
- Consume the pinned portable `Opsmaru.Incus` client over the existing `incus.sock` bridge. Shared client implementation/provenance belongs to Opsmaru; Macus verifies dependency coverage and its own backend/identity integration without a duplicate client port.
- Compose Opsmaru's shared Incus tool modules with Macus-owned Swift runtime tools at one `/mcp` endpoint using maintained TamaMCP contracts. Supply Macus's verified principal/scopes, backend and host adapter; use Opsmaru's shared cache/store/runner with private Macus-selected state.
- Install the Swift executable and matching bundled-ERTS Macus release containing the pinned Opsmaru dependency as one package. Installation is passive; `macus start` activates the same two independently supervised Swift/Elixir jobs.
- Add `macus connect [url]`, `macus connection status` and `macus disconnect`. Explicit connect enrolls this selected installation with central Opsmaru through external-provider browser authentication and device key proof, then enables an outbound connector in the existing Elixir service. Local runtime, native Incus and MCP access remain available without central registration.
- Reuse Opsmaru's registered dispatch/receipt/stream protocol for central operations against this Mac only; enforce approved local capabilities/projects, namespace delegated owners and retain Swift lifecycle/share safety. No third service, inbound port, local OIDC issuer or database is added.
- Preserve canonical checks and explicit isolated package/hardware/remote acceptance. Completed scaffold, pinned-reference foundation and Cowboy transport-trial evidence remain valid historical work; new integration tasks remain unchecked.

## Capabilities

### New Capabilities

- `server-gateway`: authenticated Macus HTTPS routes, transparent native Incus transport and listener-free shared-service embedding and optional enrolled outbound central connection.
- `incus-client`: Macus consumption and verification of the canonical shared Opsmaru client through its private bridge.
- `mcp-service`: one composed shared/host tool catalogue, Macus authorization and consumer validation of shared durable execution.

### Modified Capabilities

- `incus-transport`: retain native private relays and control API while supplying the same bridge to shared compute code.
- `client-cli`: route normal requests through the gateway and retain private administration/setup/output safety and add central connect/status/disconnect commands.
- `startup-bootstrap`: activate/verify the same two services with embedded Opsmaru configured within the original startup budget; central outage must not prevent local startup.
- `service-delivery`: package the pinned shared dependency inside Macus's matching release with provenance and no third service.

## Impact

- The first dependency milestone is Opsmaru's [add-embedded-incus-foundation](https://github.com/upmaru/opsmaru/blob/feature/phoenix-bootstrap-and-remote-access/openspec/changes/add-embedded-incus-foundation/proposal.md), delivering safe embedding and the Incus client independently. Later shared tools/tasks/connectors are tracked in the [add-compute-substrate change](https://github.com/upmaru/opsmaru/blob/feature/phoenix-bootstrap-and-remote-access/openspec/changes/add-compute-substrate/proposal.md). The first change owns the portable client and library contracts; the later change owns tools, local journal/runner, connector protocol and central target/task contracts. The central service manages registered clusters through direct HTTPS or outbound devices; central SQL and Linux connector packaging remain separate from Macus acceptance.
- Macus changes remain concentrated in `server/` gateway/identity/runtime/host composition, Swift client/startup integration and existing source/Homebrew delivery. VZ stays in `Sources/Macus/Virtualization`.
- A real immutable Opsmaru revision or released version plus lockfile is required before production builds. Editable sibling paths are development-only; startup never downloads a replacement dependency. Build metadata records the distinct Opsmaru revision alongside matched Macus Swift/server identity.
- Implementation will revise root context/docs/checks for these ownership changes. This planning revision updates the existing change artifacts and planning context, leaving the active scaffold/source files and unrelated Homebrew work intact.
- No Linux packaging requirement is introduced into Macus. Environment images, skill bundles, workspace provisioning, service previews, Docker/Compose shims, scheduling and multi-host orchestration remain later changes; Macus registers one local target and does not become the central multi-cluster service. No code migration, service activation, publication or branch merge is included in planning.
