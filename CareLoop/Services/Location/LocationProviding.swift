import CoreLocation
import Foundation

struct LocationCoordinate: Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    /// 高德 Web 服务要求的 "经度,纬度" 逗号串。
    var amapLocationString: String {
        String(format: "%.6f,%.6f", longitude, latitude)
    }
}

enum LocationError: Error, LocalizedError, Sendable {
    case unauthorized
    case unavailable
    case timeout

    var errorDescription: String? {
        switch self {
        case .unauthorized: "未获得定位权限，可在系统设置中开启"
        case .unavailable: "暂时拿不到当前位置"
        case .timeout: "定位超时，请稍后再试"
        }
    }
}

/// 一次性定位。仅在用户发起「附近」意图时调用，不做常驻更新。
protocol LocationProviding: Sendable {
    func currentLocation(timeout: TimeInterval) async throws -> LocationCoordinate
}

extension LocationProviding {
    func currentLocation() async throws -> LocationCoordinate {
        try await currentLocation(timeout: 8)
    }
}

/// 真机定位：CLLocationManager 包装，授权 → requestLocation 一次完成。
/// CLLocationManager 只在主线程创建与调用；delegate 回调先提取 Sendable 数据再落回 MainActor。
@MainActor
final class CoreLocationProvider: NSObject, LocationProviding {
    private struct LocationFix: Sendable {
        var coordinate: LocationCoordinate
        var timestamp: Date
    }

    private let manager = CLLocationManager()
    private var authContinuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private var locationContinuation: CheckedContinuation<LocationFix, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    nonisolated func currentLocation(timeout: TimeInterval) async throws -> LocationCoordinate {
        let task = Task { @MainActor in
            try await self.resolve()
        }
        return try await withThrowingTaskGroup(of: LocationCoordinate.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                task.cancel()
                throw LocationError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LocationError.unavailable }
            return first
        }
    }

    @MainActor
    private func resolve() async throws -> LocationCoordinate {
        let status: CLAuthorizationStatus
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            status = await withCheckedContinuation { continuation in
                authContinuations.append(continuation)
            }
        case .authorizedWhenInUse, .authorizedAlways:
            status = manager.authorizationStatus
        default:
            throw LocationError.unauthorized
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            throw LocationError.unauthorized
        }

        if let cached = manager.location, Date().timeIntervalSince(cached.timestamp) < 300 {
            return LocationCoordinate(
                latitude: cached.coordinate.latitude,
                longitude: cached.coordinate.longitude
            )
        }
        let fix = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                locationContinuation = continuation
                manager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor in
                self.failLocation(with: CancellationError())
            }
        }
        return fix.coordinate
    }

    @MainActor
    private func handleFix(_ fix: LocationFix) {
        locationContinuation?.resume(returning: fix)
        locationContinuation = nil
    }

    @MainActor
    private func failLocation(with error: Error) {
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }
}

extension CoreLocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = self.manager.authorizationStatus
            let continuations = authContinuations
            authContinuations.removeAll()
            for continuation in continuations {
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let fix = LocationFix(
            coordinate: LocationCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ),
            timestamp: location.timestamp
        )
        Task { @MainActor in
            self.handleFix(fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        _ = error.localizedDescription // 在 nonisolated 上下文取描述，避免把非 Sendable error 跨隔离传递
        Task { @MainActor in
            self.failLocation(with: LocationError.unavailable)
        }
    }
}

/// 固定坐标的 Mock：单测 / Demo 模式 / 模拟器用。
struct MockLocationProvider: LocationProviding {
    var coordinate: LocationCoordinate
    var error: LocationError?

    init(coordinate: LocationCoordinate = LocationCoordinate(latitude: 39.9165, longitude: 116.4540), error: LocationError? = nil) {
        self.coordinate = coordinate
        self.error = error
    }

    func currentLocation(timeout: TimeInterval) async throws -> LocationCoordinate {
        if let error { throw error }
        return coordinate
    }
}
