# Spec Delta

## ADDED Requirements

### Requirement: Trusted image acquisition

Automated acquisition SHALL select a fixed compatible ARM64 image from trusted metadata shipped with Macus. Archive and extracted-disk digests SHALL be verified before publication or runtime creation. Metadata SHALL record upstream signature verification against a pinned signer. A checksum downloaded beside an image MUST NOT establish trust on its own; unsupported catalog versions or integrity failures SHALL stop creation.

#### Scenario: Authentic pinned archive

- **WHEN** the catalogued archive is downloaded
- **THEN** it is accepted only if its exact archive and raw-disk digests match the shipped trusted entry, with upstream signer provenance available locally

#### Scenario: Tampered archive or cache

- **WHEN** an archive or previously cached raw image differs from its trusted digest
- **THEN** it is rejected before seed/runtime creation and no existing runtime data is modified

### Requirement: Bounded private appliance preparation

Acquisition and preparation SHALL use private staging and atomic publication. Extraction SHALL accept only the expected regular raw-disk member, enforce catalogued size bounds, and reject links and unsafe archive entries. Bootstrap preparation SHALL be available from an installed Macus distribution without host Python, GnuPG, Swift, or repository-relative files.

#### Scenario: Unsafe archive

- **WHEN** an archive contains traversal, extra members, links, or an oversized raw disk
- **THEN** preparation fails without writing outside its private staging directory or publishing an image

#### Scenario: Installed executable outside checkout

- **WHEN** the installed Macus executable starts from an arbitrary working directory after the checkout is unavailable
- **THEN** it has the catalog and guest bootstrap resources needed to prepare a NoCloud seed and appliance manifest

### Requirement: Boot-scoped provisioning observations

Guest provisioning SHALL expose versioned stage observations and an explicit expected-kernel-reboot signal scoped to the current boot. Observations SHALL distinguish package installation, kernel transition, storage initialization, and Incus initialization. They MUST NOT contain secrets or serve as readiness evidence. Unknown observations SHALL be ignored safely.

#### Scenario: Kernel transition

- **WHEN** the first bootstrap installs the qualified kernel and requires shutdown
- **THEN** it emits the expected-reboot observation before shutting down and leaves durable continuation registered

#### Scenario: Provisioning failure

- **WHEN** qualified kernel/ZFS packages cannot be installed or storage initialization refuses existing data
- **THEN** progress identifies failure and preserves diagnostics without substituting packages, formatting data, or advertising readiness
