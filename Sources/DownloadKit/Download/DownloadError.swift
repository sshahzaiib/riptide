import Foundation

public enum DownloadError: Error, Equatable {
    case badResponse, httpStatus(Int), cancelled, rangeUnsupported
}
