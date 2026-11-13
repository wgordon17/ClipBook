import AppKit
@testable import ClipBook
import Foundation
import Testing

@Suite struct ForkReleaseConfigTests {
    private static var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let elapsed: Duration
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let clock = ContinuousClock()
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        let elapsed = try clock.measure {
            try process.run()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            process.waitUntilExit()
            group.wait()
        }

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            elapsed: elapsed
        )
    }

    @Test func infoPlistConfiguresSignedForkSparkleFeedAndIsolatedDefaultsDomain() throws {
        let infoPlistURL = Self.repoRootURL.appendingPathComponent("ClipBook/Info.plist")
        let plistData = try Data(contentsOf: infoPlistURL)
        let rawPlist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        let info = try #require(rawPlist as? [String: Any])

        let feedURL = try #require(info["SUFeedURL"] as? String)
        #expect(feedURL == "https://github.com/wgordon17/ClipBook/releases/latest/download/appcast.xml")
        #expect(feedURL.hasPrefix("https://"))

        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SUDefaultsDomain"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER).fork.sparkle")

        let publicEDKey = try #require(info["SUPublicEDKey"] as? String)
        let decodedKey = try #require(Data(base64Encoded: publicEDKey))
        #expect(decodedKey.count == 32)

        let expandedDefaultsDomain = Bundle.main.object(forInfoDictionaryKey: "SUDefaultsDomain") as? String
        #expect(expandedDefaultsDomain == "com.ikryanov.clipbook.v2.debug.fork.sparkle")
    }

    @Test
    @MainActor
    func appDelegateDisablesSparkleUpdaterDuringHostedTests() {
        let sparkleDomain = "com.ikryanov.clipbook.v2.debug.fork.sparkle"
        let hadPreexistingDomain = UserDefaults.standard.persistentDomain(forName: sparkleDomain) != nil
        let delegate = AppDelegate()
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            if !hadPreexistingDomain, UserDefaults.standard.persistentDomain(forName: sparkleDomain) != nil {
                TestSupport.removeDefaultsSuite(named: sparkleDomain)
            }
        }
        #expect(!delegate.usesSparkleUpdaterForTests)
        delegate.coordinator.checkForUpdates()
        #expect(UserDefaults.standard.persistentDomain(forName: sparkleDomain) == nil)
    }

    @Test func upstreamVersionBaselineAndReleaseEntitlementsAreMinimal() throws {
        let versionURL = Self.repoRootURL.appendingPathComponent("FORK_UPSTREAM_VERSION")
        let rawVersion = try String(contentsOf: versionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(rawVersion.range(of: #"^[0-9]+(\.[0-9]+){1,2}$"#, options: .regularExpression) != nil)

        if let resourcesURL = Bundle.main.resourceURL {
            let bundledVersionURL = resourcesURL.appendingPathComponent("FORK_UPSTREAM_VERSION")
            #expect(!FileManager.default.fileExists(atPath: bundledVersionURL.path))
        }

        let entitlementsURL = Self.repoRootURL.appendingPathComponent("scripts/ClipBookForkRelease.entitlements")
        let entitlementsData = try Data(contentsOf: entitlementsURL)
        let rawEntitlements = try PropertyListSerialization.propertyList(from: entitlementsData, options: [], format: nil)
        let entitlements = try #require(rawEntitlements as? [String: Any])

        #expect(entitlements.count == 1)
        #expect(entitlements["com.apple.security.cs.disable-library-validation"] as? Bool == true)
    }

    @Test func shellScriptsPassBashSyntaxCheck() throws {
        let relativePaths = [
            "test.sh",
            "scripts/release-fork.sh"
        ]
        for relativePath in relativePaths {
            let scriptPath = Self.repoRootURL.appendingPathComponent(relativePath).path
            let result = try Self.runProcess(executablePath: "/bin/bash", arguments: ["-n", scriptPath])
            #expect(result.status == 0, "\(relativePath) failed bash -n: \(result.stderr)")
            #expect(result.stderr.isEmpty, "\(relativePath) emitted stderr on bash -n: \(result.stderr)")
        }
    }

    @Test func releaseForkScriptFailsClosedOnInvalidArgumentsBeforeBuilding() throws {
        let scriptPath = Self.repoRootURL.appendingPathComponent("scripts/release-fork.sh").path
        var cleanEnv = ProcessInfo.processInfo.environment
        cleanEnv.removeValue(forKey: "SPARKLE_ED25519_PRIVATE_KEY")
        cleanEnv.removeValue(forKey: "SIGNING_IDENTITY")
        cleanEnv.removeValue(forKey: "KEYCHAIN_PATH")

        try TestSupport.withTemporaryDirectory { tempDir in
            let outputDir = tempDir.appendingPathComponent("output", isDirectory: true)
            let derivedDataDir = tempDir.appendingPathComponent("derived-data", isDirectory: true)
            let dummyFile = tempDir.appendingPathComponent("dummy.input")
            try Data("placeholder".utf8).write(to: dummyFile)

            let baseArgs = [
                scriptPath,
                "--output-dir", outputDir.path,
                "--derived-data-path", derivedDataDir.path
            ]

            let cases: [(label: String, extraArgs: [String], expectedError: String)] = [
                (
                    "non-monotonic build floor",
                    ["--run-number", "5", "--previous-build", "1000005"],
                    "Monotonic build check failed"
                ),
                (
                    "zero run number",
                    ["--run-number", "0"],
                    "--run-number must be a positive integer >= 1"
                ),
                (
                    "ad-hoc signing without smoke-test",
                    ["--run-number", "1", "--signing-identity", "-"],
                    "Production build requires --p12-file or a non-adhoc --signing-identity"
                ),
                (
                    "incomplete rcodesign p12 flags",
                    ["--run-number", "1", "--p12-file", dummyFile.path],
                    "--p12-file, --p12-password-file, and --rcodesign-bin must all be provided together"
                ),
                (
                    "smoke-test combined with p12 flags",
                    [
                        "--run-number", "1",
                        "--smoke-test",
                        "--p12-file", dummyFile.path,
                        "--p12-password-file", dummyFile.path,
                        "--rcodesign-bin", "/bin/ls"
                    ],
                    "--smoke-test cannot be combined with --p12-file"
                )
            ]

            for testCase in cases {
                let result = try Self.runProcess(
                    executablePath: "/bin/bash",
                    arguments: baseArgs + testCase.extraArgs,
                    environment: cleanEnv
                )
                #expect(result.status != 0, "Expected non-zero exit for \(testCase.label)")
                #expect(
                    result.elapsed < .seconds(1),
                    "Expected fast (<1s) preflight exit for \(testCase.label), took \(result.elapsed)"
                )
                #expect(
                    result.stderr.contains(testCase.expectedError),
                    "Expected '\(testCase.expectedError)' in stderr for \(testCase.label), got: \(result.stderr)"
                )
            }
        }
    }

}
