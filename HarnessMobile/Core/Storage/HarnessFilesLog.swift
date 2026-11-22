import Foundation
import os

/// Everything about picking, importing and mounting files logs here.
/// Filter on the iPhone (Console.app / `pymobiledevice3 syslog live`) with
/// `subsystem == "com.llf.harnessmobile" && category == "files"`.
enum HarnessFilesLog {
    static let logger = Logger(subsystem: "com.llf.harnessmobile", category: "files")

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code): \(error.localizedDescription)"
    }
}
