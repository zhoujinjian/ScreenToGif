import Foundation
import os

/// 统一日志分类。
enum Log {
    static let app = Logger(subsystem: Constants.bundleIdentifier, category: "app")
    static let capture = Logger(subsystem: Constants.bundleIdentifier, category: "capture")
    static let editor = Logger(subsystem: Constants.bundleIdentifier, category: "editor")
    static let export = Logger(subsystem: Constants.bundleIdentifier, category: "export")
    static let settings = Logger(subsystem: Constants.bundleIdentifier, category: "settings")
}
