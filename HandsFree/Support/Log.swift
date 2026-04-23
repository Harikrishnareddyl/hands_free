import Foundation

/// Simple NSLog wrapper. NSLog writes to both the unified log system
/// (visible in Console.app and via `log stream`) and to stderr, so running
/// the app from Terminal shows everything live.
enum Log {
    static func info(_ tag: String, _ message: @autoclosure () -> String) {
        NSLog("[HandsFree][\(tag)] \(message())")
    }

    static func error(_ tag: String, _ message: @autoclosure () -> String) {
        NSLog("[HandsFree][\(tag)][ERROR] \(message())")
    }
}
