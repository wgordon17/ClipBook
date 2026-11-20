import Foundation
import Security
import SwiftUI
import AppKit
import Carbon
import Combine

enum AppDirectories {
  nonisolated static let usesIsolatedDebugStorage: Bool = {
    #if DEBUG
    return true
    #else
    return !isCertificateSignedRelease(signingInfo: currentProcessSigningInfo())
    #endif
  }()

  nonisolated static func currentProcessSigningInfo() -> [String: Any]? {
    var dynamicCode: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &dynamicCode) == errSecSuccess,
          let dynamicCode else {
      return nil
    }

    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode) == errSecSuccess,
          let staticCode else {
      return nil
    }

    var rawInfo: CFDictionary?
    let infoFlags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
    guard SecCodeCopySigningInformation(staticCode, infoFlags, &rawInfo) == errSecSuccess,
          let signingInfo = rawInfo as? [String: Any] else {
      return nil
    }

    return signingInfo
  }

  nonisolated static func isCertificateSignedRelease(signingInfo: [String: Any]?) -> Bool {
    guard let signingInfo,
          let identifier = signingInfo[kSecCodeInfoIdentifier as String] as? String,
          !identifier.isEmpty,
          let rawFlagsValue = signingInfo[kSecCodeInfoFlags as String],
          CFGetTypeID(rawFlagsValue as AnyObject) != CFBooleanGetTypeID() else {
      return false
    }

    let rawFlags: UInt32
    if let uint32Flags = rawFlagsValue as? UInt32 {
      rawFlags = uint32Flags
    } else if let intFlags = rawFlagsValue as? Int,
              let exact = UInt32(exactly: intFlags) {
      rawFlags = exact
    } else if let numberFlags = rawFlagsValue as? NSNumber,
              let exact = UInt32(exactly: numberFlags.int64Value) {
      rawFlags = exact
    } else {
      return false
    }

    let signatureFlags = SecCodeSignatureFlags(rawValue: rawFlags)
    guard signatureFlags.intersection([.adhoc, .linkerSigned]).isEmpty else {
      return false
    }

    guard let rawCerts = signingInfo[kSecCodeInfoCertificates as String] as? [AnyObject],
          !rawCerts.isEmpty,
          rawCerts.allSatisfy({ CFGetTypeID($0) == SecCertificateGetTypeID() }) else {
      return false
    }

    return true
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
