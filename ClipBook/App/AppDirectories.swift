import Foundation

enum AppDirectories {
  nonisolated static let usesIsolatedDebugStorage: Bool = RuntimeSigningEnvironment.usesIsolatedDebugStorage

  nonisolated static func currentProcessSigningInfo() -> [String: Any]? {
    RuntimeSigningEnvironment.currentProcessSigningInfo()
  }

  nonisolated static func isCertificateSignedRelease(signingInfo: [String: Any]?) -> Bool {
    RuntimeSigningEnvironment.isCertificateSignedRelease(signingInfo: signingInfo)
  }

  nonisolated static func supportFolderName(isDebugBuild: Bool = usesIsolatedDebugStorage) -> String {
    isDebugBuild ? "ClipBook2-Debug" : "ClipBook2"
  }

  nonisolated static func applicationSupport(
    fileManager: FileManager,
    baseDirectory: URL? = nil,
    isDebugBuild: Bool = usesIsolatedDebugStorage
  ) -> URL {
    let base = baseDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let directory = base.appendingPathComponent(supportFolderName(isDebugBuild: isDebugBuild), isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  nonisolated static func forkSupportDirectory(
    in supportDirectory: URL,
    fileManager: FileManager = .default
  ) -> URL {
    let directory = supportDirectory.appendingPathComponent("Fork", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  nonisolated static func forkSupportDirectory(
    fileManager: FileManager,
    baseDirectory: URL? = nil,
    isDebugBuild: Bool = usesIsolatedDebugStorage
  ) -> URL {
    let supportDirectory = applicationSupport(
      fileManager: fileManager,
      baseDirectory: baseDirectory,
      isDebugBuild: isDebugBuild
    )
    return forkSupportDirectory(in: supportDirectory, fileManager: fileManager)
  }
}
