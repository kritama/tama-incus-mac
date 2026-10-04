# Tasks

## 1. Local transport

- [x] 1.1 Implement owner-checked Unix HTTP requests with bounded framing and total deadlines; verify content-length, chunked/EOF, malformed/truncated, delayed-peer and unsafe-path tests and document transport limits.

## 2. Commands and output

- [x] 2.1 Keep the thin tim executable, strict lifecycle grammar and runtime requests; verified help, precedence, force payload, JSON/exit codes and conflict/timeout behavior remain for status, start, stop and restart. Inspection commands are no longer part of this task.
- [x] 2.2 Remove list/show and add client setup with PATH-first resolution, official Homebrew install when needed, prefix discovery, ready-socket registration, idempotency, conflict, optional default switching, unrelated-config preservation and bounded subprocesses; verify fixture-process and executable tests and document the workload boundary.

## 3. Single installation

- [x] 3.1 Add one local install command for both release tools with staged signing and state preservation; verify an isolated-prefix install, both executable entrypoints and daemon entitlement; document that this install does not install Incus or launchd.

## 4. Integrated acceptance

- [x] 4.1 Re-run canonical checks and strict OpenSpec validation for the revised commands; complete available CodeRabbit review of the setup slice and record its result. Prior list/show review does not cover this gate.
- [x] 4.2 Exercise installed tim client setup with the standard Incus CLI and an isolated client configuration, proving incus list can use the registered remote. Record mocked installer results separately from real registration. Do not disturb the in-use appliance or prefix, and do not treat historical lifecycle or list/show evidence as this gate.
