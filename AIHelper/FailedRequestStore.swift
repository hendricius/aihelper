import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "FailedRequestStore")

class FailedRequestStore: ObservableObject {
    @Published var failedRequests: [FailedRequest] = []

    private let storageKey = "failed_requests"
    private let maxStoredRequests = 10

    init() {
        logger.info("Initializing FailedRequestStore...")
        load()
        logger.info("FailedRequestStore initialized with \(self.failedRequests.count) failed requests")
    }

    func add(_ request: FailedRequest) {
        logger.debug("Adding failed request: \(request.errorMessage)")
        failedRequests.insert(request, at: 0)

        // Limit storage to prevent excessive memory/storage use
        if failedRequests.count > maxStoredRequests {
            let removed = failedRequests.count - maxStoredRequests
            failedRequests = Array(failedRequests.prefix(maxStoredRequests))
            logger.debug("Removed \(removed) old failed requests to stay under limit")
        }

        save()
    }

    func remove(_ request: FailedRequest) {
        let countBefore = failedRequests.count
        failedRequests.removeAll { $0.id == request.id }
        if failedRequests.count < countBefore {
            logger.debug("Removed failed request")
            save()
        }
    }

    func clearAll() {
        logger.info("Clearing all failed requests")
        failedRequests.removeAll()
        save()
    }

    var hasFailedRequests: Bool {
        !failedRequests.isEmpty
    }

    var count: Int {
        failedRequests.count
    }

    private func save() {
        do {
            let encoded = try JSONEncoder().encode(failedRequests)
            UserDefaults.standard.set(encoded, forKey: storageKey)
            logger.debug("Saved \(self.failedRequests.count) failed requests")
        } catch {
            logger.error("Failed to save failed requests: \(error.localizedDescription)")
        }
    }

    private func load() {
        do {
            if let data = UserDefaults.standard.data(forKey: storageKey) {
                failedRequests = try JSONDecoder().decode([FailedRequest].self, from: data)
                logger.info("Loaded \(self.failedRequests.count) failed requests from storage")
            }
        } catch {
            logger.error("Failed to decode failed requests: \(error.localizedDescription). Clearing corrupted data.")
            UserDefaults.standard.removeObject(forKey: storageKey)
            failedRequests = []
        }
    }
}
