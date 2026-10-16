import Foundation

/// Why a single transfer did not complete.
enum TransferError: Error, Equatable {
    /// The server's status is not a success for this task (see `DownloadSession.isSuccess`); 0 when there was no HTTP response.
    case http(Int)
    /// The transfer failed below HTTP; the payload is the error's domain and code, never its description, which can carry the URL.
    case transport(String)
    /// Cancelled by us; resume data, when the server supports ranges, is also kept at the key's resume URL.
    case cancelled(resumeData: Data?)
    /// The downloaded file could not be moved to its destination.
    case fileMove
}
