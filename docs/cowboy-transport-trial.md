# Cowboy transport trial

The `add-elixir-server` change uses Phoenix's Cowboy2 adapter after a fixture
trial of Cowboy's documented native protocol-switch mechanism. The locked
dependencies are Phoenix 1.8.15, Plug.Cowboy 2.9.0, Cowboy 2.19.0, Cowlib 2.21.0
and Ranch 2.3.0. The official Incus client remains unmodified at v7.0.1,
commit `13f3992766142d5087fff2e362cd2e1a75294fe8`; reference fixtures verify
its source hashes independently.

Run the trial from the server directory with the root mise toolchain:

```sh
mise exec -- mix test test/macus/proxy/cowboy_upgrade_test.exs
```

The test starts temporary loopback TLS 1.3 listeners and isolated Unix sockets
with disposable CA-signed identities. A fixed enrolled fixture certificate is
checked before any Unix backend connection. Custom Cowboy dispatch handles
native upgrades; other requests use the real Phoenix endpoint on the same
listener. All tunnel code lives in `test/support` and is compiled only for
tests. The production application still opens no listener.

Evidence covers:

- Official-client SFTP and NBD connection negotiation and binary round trips.
- A 512 KiB binary transfer, queries and bytes coalesced with both handshakes.
- Backend socket ownership surviving termination of Cowboy's request worker.
- Backend half-close with subsequent writes by the official client.
- Denial before backend access for anonymous upgrades, rejection of mismatched
  backend protocols, and bounded cleanup after client disconnect.
- Phoenix responding while another native connection is idle.
- Response-header CRLF rejection before a successful protocol switch.

The fixture backend echoes opaque bytes. It does not implement an SFTP server
or NBD device, and it does not prove file transfer or disk access against a
real guest. Production gateway trust/revocation, quotas, long-lived saturation,
remaining stream cases and hardware acceptance stay in the change's pending
tasks. Task 5.4 is not completed by this trial.

## Cowlib advisory

Hex flags Cowlib for [CVE-2026-43966](https://cna.erlef.org/cves/CVE-2026-43966.html),
which concerns CR/LF in structured-field header encoding. The documented
server mitigation is Cowboy 2.16 or later with
`invalid_response_headers: :error_terminate`. The trial sets that option
explicitly and tests that a malicious upgrade header produces HTTP 500 without
injecting headers or starting the tunnel. Native protocol names are fixed
allowlisted values. Preserve this guard in production listener configuration;
do not disable it or pass unchecked input into structured-field encoders.
This does not claim that Cowlib itself has a fixed release.
