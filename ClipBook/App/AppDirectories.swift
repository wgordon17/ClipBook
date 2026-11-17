import Foundation
import SwiftUI
import AppKit
import Carbon
import Combine

enum AppDirectories {
  static func applicationSupport(fileManager: FileManager) -> URL {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let directory = base.appendingPathComponent("ClipBook2", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func forkSupportDirectory(
    in supportDirectory: URL,
    fileManager: FileManager = .default
  ) -> URL {
    let directory = supportDirectory.appendingPathComponent("Fork", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
