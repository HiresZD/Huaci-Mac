import Foundation

private struct VisibilityRegressionFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct SettingsVisibilityRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw VisibilityRegressionFailure(description: message) }
    }

    static func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    static func main() throws {
        let defaults = AppSettings()
        try check(defaults.showMenuBarIcon && defaults.enabled,
                  "A new install must expose its menu bar entry point")
        let oldPaused = try decode(#"{"enabled":false,"model":"saved-model","popupAfterCopy":true,"translationTarget":"en"}"#)
        try check(oldPaused.showMenuBarIcon && !oldPaused.enabled,
                  "Upgrading must keep a previously paused app visible and paused")

        var settings = oldPaused
        settings.setShowMenuBarIcon(false)
        try check(!settings.showMenuBarIcon && settings.enabled,
                  "Hiding the menu icon must resume a paused selection assistant")
        settings.setEnabled(false)
        try check(settings.enabled,
                  "A programmatic pause must not disable a hidden selection assistant")
        try check(settings.model == "saved-model" && settings.popupAfterCopy && settings.translationTarget == "en",
                  "Visibility changes must preserve the API, compatibility and translation preferences")
        settings.setShowMenuBarIcon(true)
        try check(settings.showMenuBarIcon && settings.enabled,
                  "Showing the menu icon must leave the assistant enabled")
        settings.setEnabled(false)
        try check(!settings.enabled,
                  "A visible assistant must become pausable again")

        for visible in [true, false] {
            for enabled in [true, false] {
                let decoded = try decode("{\"showMenuBarIcon\":\(visible),\"enabled\":\(enabled)}")
                try check(decoded.showMenuBarIcon == visible,
                          "Decoding must preserve the requested icon visibility")
                try check(decoded.enabled == (enabled || !visible),
                          "Decoding must normalize hidden and disabled preferences")
                let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(decoded))
                try check(roundTrip.showMenuBarIcon == decoded.showMenuBarIcon && roundTrip.enabled == decoded.enabled,
                          "Visibility and effective enabled state must survive persistence")
                for requested in [true, false] {
                    var enabledChange = decoded
                    enabledChange.setEnabled(requested)
                    try check(enabledChange.showMenuBarIcon || enabledChange.enabled,
                              "An enabled-state mutation created an inaccessible hidden app")
                    var visibilityChange = decoded
                    visibilityChange.setShowMenuBarIcon(requested)
                    try check(visibilityChange.showMenuBarIcon || visibilityChange.enabled,
                              "An icon-visibility mutation created an inaccessible hidden app")
                }
            }
        }
        print("Menu bar visibility regression checks passed (no preferences or Keychain accessed).")
    }
}
