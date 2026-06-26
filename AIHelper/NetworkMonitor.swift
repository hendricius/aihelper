import Foundation
import Network
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "NetworkMonitor")

/// Monitors network connectivity status using NWPathMonitor
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var connectionType: ConnectionType = .unknown

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.aihelper.networkmonitor")

    enum ConnectionType {
        case wifi
        case cellular
        case ethernet
        case unknown
    }

    private init() {
        startMonitoring()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied

                // Determine connection type
                if path.usesInterfaceType(.wifi) {
                    self.connectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = .cellular
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = .ethernet
                } else {
                    self.connectionType = .unknown
                }

                // Log connection changes
                if wasConnected != self.isConnected {
                    if self.isConnected {
                        logger.info("Network connected via \(String(describing: self.connectionType))")
                    } else {
                        logger.info("Network disconnected")
                    }
                }
            }
        }

        monitor.start(queue: queue)
        logger.info("Network monitoring started")
    }

    deinit {
        monitor.cancel()
    }
}
