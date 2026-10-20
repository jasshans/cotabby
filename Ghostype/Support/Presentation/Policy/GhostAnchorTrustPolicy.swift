import Foundation

/// Separates host-measured placement from movement predicted in an unverified font. A short
/// single-line field (including Chrome's address bar) provides too little text to prove that
/// our stand-in font has the host's advances, so it must read a fresh caret after typing.
enum GhostAnchorTrustPolicy {
    static func requiresFreshCaret(isSingleLineField: Bool, hostNamesFace: Bool) -> Bool {
        isSingleLineField && !hostNamesFace
    }
}