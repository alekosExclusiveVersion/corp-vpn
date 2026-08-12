import Foundation
import SystemConfiguration

let targetNames = ["vpn2-ts", "vpn3-ts", "vpn4"]

guard let prefs = SCPreferencesCreate(nil, "split-fix" as CFString, nil) else {
    print("ERROR: cannot create SCPreferences")
    exit(1)
}
guard let serviceList = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {
    print("ERROR: cannot get network services")
    exit(1)
}

var found = false
for service in serviceList {
    guard let name = SCNetworkServiceGetName(service) as String? else { continue }
    guard targetNames.contains(name) else { continue }
    found = true

    guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4) else {
        print("\(name): no IPv4 protocol")
        continue
    }
    var cfg = SCNetworkProtocolGetConfiguration(proto) as? [CFString: Any] ?? [:]
    cfg[kSCPropNetIPv4ConfigMethod] = kSCValNetIPv4ConfigMethodPPP
    cfg[kSCPropNetOverridePrimary] = nil
    if !SCNetworkProtocolSetConfiguration(proto, cfg as CFDictionary) {
        print("\(name): FAILED to set IPv4 config")
        continue
    }
    print("\(name): OverridePrimary removed")
}

if !found {
    print("ERROR: services not found")
    exit(1)
}
if !SCPreferencesCommitChanges(prefs) {
    print("ERROR: commit failed")
    exit(1)
}
if !SCPreferencesApplyChanges(prefs) {
    print("ERROR: apply failed")
    exit(1)
}
print("OK: split tunnel applied")
