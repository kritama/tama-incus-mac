# Homebrew candidates

The shared tap is [upmaru/homebrew-tap](https://github.com/upmaru/homebrew-tap). Its scaffold is ready; `brew install upmaru/tap/macus` becomes available after verified candidate assets and a completed formula are published. The source formula template here is canonical for both local generation and shared export.

Candidates are development packages, ad-hoc signed with `com.apple.security.virtualization`, without Developer ID signing or notarization. Runtime support is Apple Silicon and macOS 15+. Bottle coverage is the actual verified ARM64 macOS tag; the deployment target alone does not prove bottle compatibility. Source builds require Xcode 27 / Swift 6.4. Packaging requires Python 3.11+ and Homebrew 7 with formula trust support.

## Local generation and package acceptance

Start from a clean committed feature branch. Use an ignored fresh output directory:

```sh
python3 Packaging/homebrew/candidate.py prepare --output .integration/homebrew-candidate
python3 Packaging/homebrew/candidate.py build --opt-in --candidate .integration/homebrew-candidate
brew uninstall upmaru/macus-local/macus
python3 Packaging/homebrew/candidate.py install --opt-in --candidate .integration/homebrew-candidate
```

The build creates a local Git tap, trusts only its generated formula, builds through Homebrew, checks the installed signature/entitlement, generates Homebrew bottle JSON and runs style/audit. The middle uninstall removes the source-built test keg before anything has started a service. Installation then uses `--force-bottle` and requires a receipt showing a poured bottle from the expected tap; source fallback is not bottle evidence.

These opt-in mutations refuse an existing Macus package, another `macus` on PATH or an unrelated local tap. Use a dedicated package environment: runtime isolation or a new account does not isolate machine-wide Homebrew. Candidate data, logs and partial installs are retained on failure for explicit recovery. No package command starts launchd or a VM. Generated artifacts must not be committed.

`candidate.json` records commit, development version, measured digests, platform, toolchain and signing mode. `package-acceptance.json` records the installed keg and poured receipt. Rerun package checks with `python3 Packaging/homebrew/candidate.py verify --candidate /absolute/candidate`. Dirty inputs, symlink outputs, reused directories, placeholder hashes and changed artifacts are refused.

## Explicit hardware acceptance

Use the installed binary and existing opt-in runner with fresh short state and a report outside the runtime/install directories:

```sh
export MACUS_BREW_TEST_ROOT="$(mktemp -d /private/tmp/macus-brew.XXXXXX)"
export MACUS_BREW_TEST_PREFIX="$(brew --prefix upmaru/macus-local/macus)"
python3 Integration/scripts/start-acceptance.py --opt-in --hardware \
  --state-dir "$MACUS_BREW_TEST_ROOT/state" --prefix "$MACUS_BREW_TEST_PREFIX" \
  --macus "$MACUS_BREW_TEST_PREFIX/bin/macus" --remote macus-brew-test \
  --report "$MACUS_BREW_TEST_ROOT/start.json"
```

The runner records its isolated `INCUS_CONF`; retain that configuration for standard Incus connectivity/workload persistence checks. Never target ordinary runtime or client state. Failures retain disks and logs. The binary embeds its verified Alpine catalog and guest payload and does not need the checkout.

## Upgrade and removal

Stop the runtime, confirm it is stopped, then unload its owned service before package changes. `runtime stop` does not unload launchd. Get the label/plist from startup and the selected state: default `com.upmaru.macus`, isolated `com.upmaru.macus.<state-hash>`.

```sh
macus --state-dir /absolute/selected/state runtime stop
macus --state-dir /absolute/selected/state runtime status
launchctl bootout "gui/$(id -u)/OWNED_SERVICE_LABEL"
brew upgrade upmaru/tap/macus
macus --state-dir /absolute/selected/state start
```

Replace the example state and label with the exact owned registration. New Homebrew registrations use validated `opt/macus/bin/macus`; after stop/unload the opt link can advance without leaving a removed keg path. An old versioned-keg plist remains a conflict: explicitly remove only its owned plist after stop/unload, then start again. Registration replacement is never implicit.

Before uninstall, use the same stop/status/bootout sequence, remove only the owned plist, then `brew uninstall upmaru/tap/macus` (or the local test formula). Retain runtime disks and Incus configuration. Rollback reinstalls a retained verified prior bottle after stop/unload; it does not replace or downgrade guest disks.

## Shared export and CI

The PR/manually dispatched candidate workflow builds and pours a local bottle and retains artifacts. It does not publish releases, modify the shared tap or boot a VM. With publication authorization, upload the exact source and single-hyphen URL bottle filenames recorded in `candidate.json` as immutable development assets. Do not replace existing candidate assets.

After those HTTPS assets exist, prepare a tap feature PR using:

```sh
python3 Packaging/homebrew/candidate.py export --candidate /absolute/candidate \
  --source-url https://github.com/upmaru/macus/releases/download/CANDIDATE_VERSION/SOURCE_ARCHIVE \
  --bottle-root https://github.com/upmaru/macus/releases/download/CANDIDATE_VERSION \
  --destination /absolute/homebrew-tap/Formula/macus.rb
```

Replace uppercase examples with actual generated names. Export checks remote bytes against measured hashes, requires version-specific HTTPS URLs and refuses an existing destination. Macus code PRs target `develop`; tap formula PRs target `main`. Development acceptance is not a stable production release or authorization to finish Git Flow branches.
