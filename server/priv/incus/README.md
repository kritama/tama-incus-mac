# Incus reference inventory

The verification reference is official Incus v7.0.1, immutable commit
`13f3992766142d5087fff2e362cd2e1a75294fe8`. `reference.json` records the source,
module and license. `inventory.json` contains all exported functions, concrete
methods, interface methods, types, constants and variables in `client` and
`shared/api`, including build-constrained declarations. Embedded interfaces
and model fields remain in canonical Go type signatures. Standard-library and
third-party transport types in signatures retain their upstream names.

No entry is implemented merely because it is listed. Each entry has an
`elixir` mapping and `evidence` list, initially null/empty. API methods and
models require typed-client evidence; native raw-proxy tests are separate.
There are 1,280 entries from 86 source files at this revision.

Fetch the reference into ignored state from the repository root:

```sh
git clone --depth 1 --branch v7.0.1 https://github.com/lxc/incus.git .integration/incus-reference
git -C .integration/incus-reference rev-parse HEAD
```

Then generate twice from `server/` and compare:

```sh
mise exec -- mix macus.incus.inventory --source ../.integration/incus-reference
mise exec -- mix macus.incus.inventory --source ../.integration/incus-reference --output ../.integration/incus-inventory-repeat.json
cmp priv/incus/inventory.json ../.integration/incus-inventory-repeat.json
```

Generation refuses a dirty checkout or a commit different from the pin. Source
SHA-256 hashes and paths/lines are included. The Go parser uses the standard
library only; Go 1.25.14 is a development verifier and is never packaged as a
sidecar. Its discriminating parser regression runs from the repository root:

```sh
GO111MODULE=off GOTOOLCHAIN=local mise exec -- go test ./server/scripts
```

Before changing the reference, retain the previous inventory, update the
explicit pin and notices, regenerate from the new verified checkout, and use
`Macus.Incus.Inventory.diff/2` to review added, removed and changed signatures.
Changes in source hashes also require behavioral review, even when signatures
are unchanged. Every affected method/model needs fresh differential evidence
before the new reference is described as fully supported.
