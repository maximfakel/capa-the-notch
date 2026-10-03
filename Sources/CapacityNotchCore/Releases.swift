import Foundation

/// Where a newer CapaTheNotch is found.
///
/// Updates are fetched by hand: an ad-hoc signature is new with every build,
/// so an updater could not keep the permissions macOS granted the last one,
/// and the repository is private, so the application could not ask GitHub
/// about it without a token — which it will not hold. The person opens the
/// page, signed in as they already are.
public enum Releases {
    public static let latest = URL(string: "https://github.com/maximfakel/capa-the-notch/releases/latest")!
}
