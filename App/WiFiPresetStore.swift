import Foundation

struct WiFiPreset: Codable, Equatable {
    let ssid: String
    var channel: UInt8
    var isOpen: Bool
}

enum WiFiPresetStore {
    private static let presetsKey = "wifiPresets.v1"
    private static let selectedKey = "selectedWiFiPreset"

    static func presets() -> [WiFiPreset] {
        var values: [WiFiPreset] = []
        if let data = UserDefaults.standard.data(forKey: presetsKey),
           let decoded = try? JSONDecoder().decode([WiFiPreset].self, from: data) {
            values = decoded
        }
        if UserDefaults.standard.data(forKey: presetsKey) == nil, let legacy = UserDefaults.standard.string(forKey: "wifiSSID"), !legacy.isEmpty {
            let channel = UInt8(UserDefaults.standard.object(forKey: "wifiChannel") as? Int ?? 36)
            values = [WiFiPreset(ssid: legacy, channel: channel, isOpen: false)]
            persist(values)
            UserDefaults.standard.set(legacy, forKey: selectedKey)
        }
        return values.sorted { $0.ssid.localizedStandardCompare($1.ssid) == .orderedAscending }
    }

    static func selected() -> WiFiPreset? {
        let values = presets()
        guard !values.isEmpty else { return nil }
        let selected = UserDefaults.standard.string(forKey: selectedKey)
        return values.first { $0.ssid == selected } ?? values.first
    }

    static func upsert(ssid: String, channel: UInt8, isOpen: Bool) {
        var values = presets()
        if let index = values.firstIndex(where: { $0.ssid == ssid }) {
            values[index].channel = channel; values[index].isOpen = isOpen
        } else {
            values.append(WiFiPreset(ssid: ssid, channel: channel, isOpen: isOpen))
        }
        persist(values)
        UserDefaults.standard.set(ssid, forKey: "wifiSSID")
        UserDefaults.standard.set(Int(channel), forKey: "wifiChannel")
        UserDefaults.standard.set(ssid, forKey: selectedKey)
    }

    static func select(_ ssid: String) {
        guard presets().contains(where: { $0.ssid == ssid }) else { return }
        UserDefaults.standard.set(ssid, forKey: selectedKey)
    }

    static func remove(_ ssid: String) {
        let values = presets().filter { $0.ssid != ssid }
        persist(values)
        if UserDefaults.standard.string(forKey: "wifiSSID") == ssid {
            UserDefaults.standard.removeObject(forKey: "wifiSSID")
            UserDefaults.standard.removeObject(forKey: "wifiChannel")
        }
        if UserDefaults.standard.string(forKey: selectedKey) == ssid {
            UserDefaults.standard.set(values.first?.ssid, forKey: selectedKey)
        }
    }

    private static func persist(_ values: [WiFiPreset]) {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: presetsKey)
        }
    }
}
