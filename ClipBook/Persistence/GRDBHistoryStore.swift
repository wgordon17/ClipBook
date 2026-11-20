import Foundation
import GRDB

nonisolated enum GRDBRuntimeInfo {
    static func makeInMemoryQueue() throws -> DatabaseQueue {
        try DatabaseQueue()
    }

    static func sqliteVersion() throws -> String {
        try makeInMemoryQueue().read { db in
            try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? ""
        }
    }
}
