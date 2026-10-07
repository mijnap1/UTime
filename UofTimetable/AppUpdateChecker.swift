import Foundation

struct AppUpdate {
    let version: String
    let storeURL: URL
}

enum AppUpdateChecker {
    private struct LookupResponse: Decodable {
        struct Result: Decodable {
            let version: String
            let trackViewUrl: URL
        }
        let results: [Result]
    }

    static func availableUpdate(bundleID: String = Bundle.main.bundleIdentifier ?? "com.jamie.UTime") async -> AppUpdate? {
        guard let installed = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleID)") else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = try? JSONDecoder().decode(LookupResponse.self, from: data).results.first,
              latest.trackViewUrl.scheme == "https",
              latest.trackViewUrl.host()?.hasSuffix("apple.com") == true,
              isVersion(latest.version, newerThan: installed) else { return nil }

        return AppUpdate(version: latest.version, storeURL: latest.trackViewUrl)
    }

    static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = installed.split(separator: ".").map { Int($0) ?? 0 }

        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
