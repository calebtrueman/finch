// SPDX-License-Identifier: MIT OR Apache-2.0
// The host name for swift-foundation's _ProcessInfo (its own version is
// compiled only outside Foundation.framework).
import Darwin

extension Platform {
    static func getHostname() -> String {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(MAXHOSTNAMELEN) + 1) {
            guard gethostname($0.baseAddress!, Int(MAXHOSTNAMELEN)) == 0 else { return "localhost" }
            return String(cString: $0.baseAddress!)
        }
    }
}
