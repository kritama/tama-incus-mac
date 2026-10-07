import Foundation

struct ApplianceCatalogEntry: Sendable, Equatable {
  var schemaVersion: Int
  var id: String
  var architecture: String
  var archiveName: String
  var archiveURL: URL
  var archiveSHA512: String
  var archiveBytes: Int64
  var memberName: String
  var rawBytes: Int64
  var rawSHA256: String
  var signerFingerprint: String
  var signingKeyURL: URL
  var verifiedWith: String
  var verifiedAt: String
  var catalogVersion: Int
  var manifestVersion: Int
  var helperVersion: Int
  var qualifiedPackages: [String: String]
  var guestPayloadRevision: String

  static let current = ApplianceCatalogEntry(
    schemaVersion: 1,
    id: "alpine-3.24.2-incus-v1",
    architecture: "arm64",
    archiveName: "alpine-3.24.2-aarch64-cloudinit-metal-r0.raw.tar.gz",
    archiveURL: URL(
      string:
        "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/alpine-3.24.2-aarch64-cloudinit-metal-r0.raw.tar.gz"
    )!,
    archiveSHA512:
      "d8ed6f0fa98d15218c351d2903d961b2cec68a7fd39ec8567fae9c49d943ae21f5cd56754497480a0cf899332acc632617b531b153e12e81d1f021c81f634518",
    archiveBytes: 626_889_284,
    memberName: "disk.raw",
    rawBytes: 1_073_741_824,
    rawSHA256: "47c0b69be2a3458c2a1ff11519e8f4b3f6565a73e89a2fe2294ed0ca3e496516",
    signerFingerprint: "F26ADFADBAE702EF7AF637459DA7EF23BFFCDF22",
    signingKeyURL: URL(string: "https://alpinelinux.org/keys/tomalok.asc")!,
    verifiedWith: "Integration/scripts/verify-appliance.py",
    verifiedAt: "2026-10-07",
    catalogVersion: 1,
    manifestVersion: 1,
    helperVersion: 1,
    qualifiedPackages: [
      "incus": ">=7.0.1",
      "linux-lts": "6.18.55-r0",
      "zfs": "2.4.4-r0",
      "zfs-libs": "2.4.4-r0",
      "zfs-lts": "6.18.55-r0",
      "zfs-openrc": "2.4.4-r0",
    ],
    guestPayloadRevision: EmbeddedGuestPayload.revision)
}
