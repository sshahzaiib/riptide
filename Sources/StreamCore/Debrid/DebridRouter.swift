import Foundation

/// Routes magnet adds to the preferred debrid service, failing over ONCE to
/// the other configured service on a terminal failure. Cancellation always
/// propagates; there is no failover on it.
public struct DebridRouter: Sendable {
    public struct Placed: Sendable, Equatable {
        public let serviceID: DebridServiceID
        public let transfer: DebridTransfer
    }

    let rd: DebridService?
    let ad: DebridService?

    public init(rd: DebridService?, ad: DebridService?) {
        self.rd = rd
        self.ad = ad
    }

    public func service(_ id: DebridServiceID) -> DebridService? {
        switch id {
        case .realDebrid: rd
        case .allDebrid: ad
        }
    }

    public func addWithFailover(magnet: String,
                                preferring: DebridServiceID?) async throws -> Placed {
        let preferred = preferring ?? .realDebrid
        guard let primary = service(preferred) ?? (preferred == .realDebrid ? ad : rd)
        else { throw DebridRouterError.noServiceConfigured }
        let fallback = primary.serviceID == .realDebrid ? ad : rd

        do {
            let transfer = try await primary.addMagnet(magnet)
            if case .failed = transfer.status, let fallback {
                return Placed(serviceID: fallback.serviceID,
                              transfer: try await fallback.addMagnet(magnet))
            }
            return Placed(serviceID: primary.serviceID, transfer: transfer)
        } catch {
            if error.isCancellation { throw error }
            guard let fallback else { throw error }
            return Placed(serviceID: fallback.serviceID,
                          transfer: try await fallback.addMagnet(magnet))
        }
    }
}

public enum DebridRouterError: Error, Equatable, Sendable {
    case noServiceConfigured
}
