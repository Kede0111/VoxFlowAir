import Foundation

/// Identifiers derived from the base bundle identifier set in Config/VoxFlowAir.xcconfig.
///
/// The app publishes the value in its Info.plist (`VoxFlowAirBundleID`); tools and tests,
/// which have no such key, fall back to the default.
public enum AppIdentity {
    public static let defaultBundleID = "be.jackfrom.voxflowair"

    public static let bundleID: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "VoxFlowAirBundleID") as? String
        guard let value, !value.isEmpty, !value.hasPrefix("$(") else { return defaultBundleID }
        return value
    }()

    /// Bundle identifier of the virtual audio driver; its device UIDs start with it.
    public static var driverBundleID: String { bundleID + ".driver" }
}
