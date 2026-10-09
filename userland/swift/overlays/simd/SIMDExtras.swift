// SPDX-License-Identifier: MIT OR Apache-2.0
// Additions to the historical simd overlay that Apple's current one has:
// Hashable quaternions. (Its vectors' _descriptionAsArray is made
// @inlinable, as Apple's is, when overlays.sh expands simd.swift.gyb.)

extension simd_quatf: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(vector)
  }
}

extension simd_quatd: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(vector)
  }
}
