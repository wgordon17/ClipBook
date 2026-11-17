import AppKit
@testable import ClipBook
import CryptoKit
import Foundation
import Security
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
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        stdinData: Data? = nil
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

        let stdinPipe: Pipe?
        if stdinData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        try process.run()
        if let stdinData, let stdinPipe {
            try stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
            try stdinPipe.fileHandleForWriting.close()
        }
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

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private static func installSentinelStubTools(
        named toolNames: [String],
        in directory: URL
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        : > "$STUB_INVOKED_SENTINEL"
        exit 99
        """
        for name in toolNames {
            let toolURL = directory.appendingPathComponent(name)
            try Data(script.utf8).write(to: toolURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
        }
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
        #expect(publicEDKey != "oQDl3fpWpRKjRpG5Dkyt3iE7uFGw8Xu6/cL1W5oeFTc=", "SUPublicEDKey must be the fork key, not upstream's")

        let expandedDefaultsDomain = Bundle.main.object(forInfoDictionaryKey: "SUDefaultsDomain") as? String
        #expect(expandedDefaultsDomain == "com.ikryanov.clipbook.v2.debug.fork.sparkle")
    }

    @Test func publicCodeSigningCertificateParsesWithForkCommonName() throws {
        let certURL = Self.repoRootURL.appendingPathComponent("scripts/ClipBookForkCodeSigning.crt")
        let pem = try String(contentsOf: certURL, encoding: .utf8)
        #expect(!pem.contains("PRIVATE KEY"))
        #expect(pem.components(separatedBy: "-----BEGIN ").count - 1 == 1)

        let pemBody = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        let derData = try #require(Data(base64Encoded: pemBody, options: .ignoreUnknownCharacters))
        #expect(!derData.isEmpty)

        let certificate = try #require(SecCertificateCreateWithData(nil, derData as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "ClipBook Fork Code Signing")

        // Verify macOS Security trust evaluation succeeds for Code Signing when self-anchored
        // (checking temporal validity and signature) yet rejects TLS server policy due to critical codeSigning EKU.
        let codeSignPolicy = try #require(SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil))
        var codeSignTrust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, codeSignPolicy, &codeSignTrust) == errSecSuccess)
        let unwrappedCodeSignTrust = try #require(codeSignTrust)
        #expect(SecTrustSetAnchorCertificates(unwrappedCodeSignTrust, [certificate] as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(unwrappedCodeSignTrust, true) == errSecSuccess)
        var codeSignError: CFError?
        #expect(
            SecTrustEvaluateWithError(unwrappedCodeSignTrust, &codeSignError),
            "AppleCodeSigning policy evaluation failed: \(String(describing: codeSignError))"
        )

        let sslPolicy = SecPolicyCreateSSL(true, "ClipBook Fork Code Signing" as CFString)
        var sslTrust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, sslPolicy, &sslTrust) == errSecSuccess)
        let unwrappedSSLTrust = try #require(sslTrust)
        #expect(SecTrustSetAnchorCertificates(unwrappedSSLTrust, [certificate] as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(unwrappedSSLTrust, true) == errSecSuccess)
        var sslError: CFError?
        #expect(!SecTrustEvaluateWithError(unwrappedSSLTrust, &sslError))

        // Verify exact X.509 v3 critical constraints and non-expiry (>= 24h remaining) via /usr/bin/openssl.
        let opensslResult = try Self.runProcess(
            executablePath: "/usr/bin/openssl",
            arguments: ["x509", "-in", certURL.path, "-noout", "-text", "-checkend", "86400"]
        )
        #expect(
            opensslResult.status == 0,
            "Certificate failed openssl x509 / 24h expiry check: \(opensslResult.stderr) \(opensslResult.stdout)"
        )
        let certText = opensslResult.stdout
        #expect(certText.contains("RSA Public-Key: (3072 bit)"))
        #expect(!certText.contains("CA:TRUE"))
        #expect(
            certText.range(
                of: #"X509v3 Basic Constraints:\s*critical\r?\n\s*CA:FALSE\r?\n"#,
                options: .regularExpression
            ) != nil
        )
        #expect(
            certText.range(
                of: #"X509v3 Key Usage:\s*critical\r?\n\s*Digital Signature\r?\n"#,
                options: .regularExpression
            ) != nil
        )
        #expect(
            certText.range(
                of: #"X509v3 Extended Key Usage:\s*critical\r?\n\s*Code Signing\r?\n"#,
                options: .regularExpression
            ) != nil
        )
    }

    @Test
    @MainActor
    func appDelegateDisablesSparkleUpdaterDuringHostedTests() {
        let sparkleDomain = "com.ikryanov.clipbook.v2.debug.fork.sparkle"
        let preexistingDomain = UserDefaults.standard.persistentDomain(forName: sparkleDomain)
        let delegate = AppDelegate()
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            let currentDomain = UserDefaults.standard.persistentDomain(forName: sparkleDomain)
            if let preexistingDomain {
                if currentDomain.map({ NSDictionary(dictionary: $0) }) != NSDictionary(dictionary: preexistingDomain) {
                    UserDefaults.standard.setPersistentDomain(preexistingDomain, forName: sparkleDomain)
                }
            } else if currentDomain != nil {
                TestSupport.removeDefaultsSuite(named: sparkleDomain)
            }
        }
        #expect(!delegate.usesSparkleUpdaterForTests)
        delegate.model.preferences.checkForUpdatesAutomatically = true
        delegate.coordinator.applyUpdatePreferences()
        delegate.model.preferences.checkForUpdatesAutomatically = false
        delegate.coordinator.applyUpdatePreferences()
        delegate.coordinator.checkForUpdates()
        let postDomain = UserDefaults.standard.persistentDomain(forName: sparkleDomain)
        #expect(
            postDomain.map { NSDictionary(dictionary: $0) }
                == preexistingDomain.map { NSDictionary(dictionary: $0) }
        )
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
            "scripts/release-fork.sh",
            "scripts/bootstrap-fork-signing.sh"
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

        try TestSupport.withTemporaryDirectory { tempDir in
            let stubBinDir = tempDir.appendingPathComponent("stub-bin", isDirectory: true)
            let sentinelFile = tempDir.appendingPathComponent("xcodebuild.invoked")
            try Self.installSentinelStubTools(named: ["xcodebuild"], in: stubBinDir)

            var cleanEnv = ProcessInfo.processInfo.environment
            cleanEnv.removeValue(forKey: "SPARKLE_ED25519_PRIVATE_KEY")
            cleanEnv.removeValue(forKey: "SIGNING_IDENTITY")
            cleanEnv.removeValue(forKey: "KEYCHAIN_PATH")
            cleanEnv.removeValue(forKey: "APP_ARCHS")
            cleanEnv.removeValue(forKey: "SPARKLE_BIN")
            cleanEnv.removeValue(forKey: "DERIVED_DATA_PATH")
            let basePath = cleanEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            cleanEnv["PATH"] = "\(stubBinDir.path):\(basePath)"
            cleanEnv["STUB_INVOKED_SENTINEL"] = sentinelFile.path

            let outputDir = tempDir.appendingPathComponent("output", isDirectory: true)
            let derivedDataDir = tempDir.appendingPathComponent("derived-data", isDirectory: true)
            let dummyFile = tempDir.appendingPathComponent("dummy.input")
            try Data("placeholder".utf8).write(to: dummyFile)

            let emptyEdKeyFile = tempDir.appendingPathComponent("empty-ed.key")
            try Data("  \n\t\n".utf8).write(to: emptyEdKeyFile)

            let shortEdKeyFile = tempDir.appendingPathComponent("short-ed.key")
            try Data(Data(repeating: 0x42, count: 16).base64EncodedString().utf8).write(to: shortEdKeyFile)

            let mismatchedEdKeyFile = tempDir.appendingPathComponent("mismatched-ed.key")
            let mismatchedSeed = Data(Curve25519.Signing.PrivateKey().rawRepresentation).base64EncodedString()
            try Data(mismatchedSeed.utf8).write(to: mismatchedEdKeyFile)

            let p12Passphrase = "test-p12-passphrase"
            let p12PassFile = tempDir.appendingPathComponent("good-p12.pass")
            try Data(p12Passphrase.utf8).write(to: p12PassFile)
            let wrongP12PassFile = tempDir.appendingPathComponent("wrong-p12.pass")
            try Data("wrong-passphrase".utf8).write(to: wrongP12PassFile)

            func makeTestPKCS12(named prefix: String, days: Int) throws -> URL {
                let keyURL = tempDir.appendingPathComponent("\(prefix).key")
                let crtURL = tempDir.appendingPathComponent("\(prefix).crt")
                let p12URL = tempDir.appendingPathComponent("\(prefix).p12")
                let reqResult = try Self.runProcess(
                    executablePath: "/usr/bin/openssl",
                    arguments: [
                        "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", keyURL.path,
                        "-out", crtURL.path,
                        "-sha256", "-days", "\(days)",
                        "-subj", "/CN=ClipBook Fork Code Signing"
                    ]
                )
                #expect(reqResult.status == 0, "openssl req failed: \(reqResult.stderr)")
                let exportResult = try Self.runProcess(
                    executablePath: "/usr/bin/openssl",
                    arguments: [
                        "pkcs12", "-export",
                        "-inkey", keyURL.path,
                        "-in", crtURL.path,
                        "-name", "ClipBook Fork Code Signing",
                        "-certpbe", "PBE-SHA1-3DES",
                        "-keypbe", "PBE-SHA1-3DES",
                        "-macalg", "sha1",
                        "-passout", "stdin",
                        "-out", p12URL.path
                    ],
                    stdinData: Data(p12Passphrase.utf8)
                )
                #expect(exportResult.status == 0, "openssl pkcs12 export failed: \(exportResult.stderr)")
                return p12URL
            }

            let shortLivedP12 = try makeTestPKCS12(named: "short-lived", days: 1)
            let mismatchedCertP12 = try makeTestPKCS12(named: "mismatched-cert", days: 365)

            let baseArgs = [
                scriptPath,
                "--output-dir", outputDir.path,
                "--derived-data-path", derivedDataDir.path
            ]

            let cases: [(label: String, extraArgs: [String], expectedError: String)] = [
                (
                    "missing option value",
                    ["--run-number"],
                    "Option --run-number requires a value"
                ),
                (
                    "unknown option",
                    ["--unknown-flag"],
                    "Unknown option: --unknown-flag"
                ),
                (
                    "nonexistent ed-key-file",
                    ["--run-number", "1", "--ed-key-file", tempDir.appendingPathComponent("missing.key").path],
                    "--ed-key-file file does not exist"
                ),
                (
                    "non-executable rcodesign-bin",
                    [
                        "--run-number", "1",
                        "--p12-file", dummyFile.path,
                        "--p12-password-file", dummyFile.path,
                        "--rcodesign-bin", dummyFile.path
                    ],
                    "--rcodesign-bin is missing or not executable"
                ),
                (
                    "incomplete rcodesign p12 flags under smoke-test",
                    ["--run-number", "1", "--smoke-test", "--p12-file", dummyFile.path],
                    "--p12-file, --p12-password-file, and --rcodesign-bin must all be provided together"
                ),
                (
                    "smoke-test combined with ed-key-file",
                    [
                        "--run-number", "1",
                        "--smoke-test",
                        "--ed-key-file", dummyFile.path
                    ],
                    "--smoke-test cannot be combined with --ed-key-file"
                ),
                (
                    "invalid repo slug",
                    ["--run-number", "1", "--repo", "bad slug/repo"],
                    "Invalid --repo slug"
                ),
                (
                    "invalid upstream version",
                    ["--run-number", "1", "--upstream-version", "2.1.0-beta"],
                    "Upstream version must match X.Y or X.Y.Z"
                ),
                (
                    "zero run number",
                    ["--run-number", "0"],
                    "--run-number must be a positive integer >= 1"
                ),
                (
                    "non-numeric previous build",
                    ["--run-number", "1", "--previous-build", "abc"],
                    "--previous-build must be a non-negative integer"
                ),
                (
                    "non-monotonic build floor",
                    ["--run-number", "5", "--previous-build", "1000005"],
                    "Monotonic build check failed"
                ),
                (
                    "invalid arch token",
                    ["--run-number", "1", "--arch-list", "arm64;bad"],
                    "Invalid architecture token in --arch-list"
                ),
                (
                    "ad-hoc signing without smoke-test",
                    ["--run-number", "1", "--signing-identity", "-"],
                    "Production build requires --p12-file or a non-adhoc --signing-identity"
                ),
                (
                    "production missing ed-key-file",
                    ["--run-number", "1"],
                    "Production build requires Sparkle Ed25519 private key via --ed-key-file"
                ),
                (
                    "production whitespace-only ed-key-file",
                    ["--run-number", "1", "--ed-key-file", emptyEdKeyFile.path],
                    "Production build requires Sparkle Ed25519 private key via --ed-key-file"
                ),
                (
                    "production non-32-byte ed-key-file",
                    ["--run-number", "1", "--ed-key-file", shortEdKeyFile.path],
                    "Sparkle Ed25519 private key must decode to a 32-byte raw seed"
                ),
                (
                    "production mismatched 32-byte ed-key-file",
                    ["--run-number", "1", "--ed-key-file", mismatchedEdKeyFile.path],
                    "does not match ClipBook/Info.plist SUPublicEDKey"
                ),
                (
                    "p12 wrong passphrase",
                    [
                        "--run-number", "1",
                        "--p12-file", mismatchedCertP12.path,
                        "--p12-password-file", wrongP12PassFile.path,
                        "--rcodesign-bin", "/bin/ls",
                        "--ed-key-file", mismatchedEdKeyFile.path
                    ],
                    "Could not extract leaf certificate PEM from PKCS#12 file"
                ),
                (
                    "production p12 expiring within 48h",
                    [
                        "--run-number", "1",
                        "--p12-file", shortLivedP12.path,
                        "--p12-password-file", p12PassFile.path,
                        "--rcodesign-bin", "/bin/ls",
                        "--ed-key-file", mismatchedEdKeyFile.path
                    ],
                    "PKCS#12 leaf certificate is expired or expires within 172800 seconds"
                ),
                (
                    "production p12 leaf fingerprint mismatch against ClipBookForkCodeSigning.crt",
                    [
                        "--run-number", "1",
                        "--p12-file", mismatchedCertP12.path,
                        "--p12-password-file", p12PassFile.path,
                        "--rcodesign-bin", "/bin/ls",
                        "--ed-key-file", mismatchedEdKeyFile.path
                    ],
                    "does not match committed scripts/ClipBookForkCodeSigning.crt"
                )
            ]

            for testCase in cases {
                try? FileManager.default.removeItem(at: sentinelFile)
                let result = try Self.runProcess(
                    executablePath: "/bin/bash",
                    arguments: baseArgs + testCase.extraArgs,
                    environment: cleanEnv
                )
                #expect(result.status != 0, "Expected non-zero exit for \(testCase.label)")
                #expect(result.status != 99, "Stub xcodebuild was unexpectedly invoked for \(testCase.label)")
                #expect(
                    !FileManager.default.fileExists(atPath: sentinelFile.path),
                    "xcodebuild must not run before preflight fails for \(testCase.label)"
                )
                #expect(
                    !result.stdout.contains("Preparing fork release"),
                    "Release build banner must not print for failed preflight \(testCase.label)"
                )
                #expect(
                    result.stderr.contains(testCase.expectedError),
                    "Expected '\(testCase.expectedError)' in stderr for \(testCase.label), got: \(result.stderr)"
                )
            }
        }
    }

    @Test func bootstrapForkSigningScriptFailsClosedOnInvalidArguments() throws {
        let scriptPath = Self.repoRootURL.appendingPathComponent("scripts/bootstrap-fork-signing.sh").path

        try TestSupport.withTemporaryDirectory { tempDir in
            let stubBinDir = tempDir.appendingPathComponent("stub-bin", isDirectory: true)
            let sentinelFile = tempDir.appendingPathComponent("bootstrap-side-effect.invoked")
            try Self.installSentinelStubTools(
                named: ["gh", "security", "xcodebuild", "mktemp"],
                in: stubBinDir
            )

            var cleanEnv = ProcessInfo.processInfo.environment
            cleanEnv.removeValue(forKey: "SPARKLE_BIN")
            cleanEnv.removeValue(forKey: "DERIVED_DATA_PATH")
            let basePath = cleanEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            cleanEnv["PATH"] = "\(stubBinDir.path):\(basePath)"
            cleanEnv["STUB_INVOKED_SENTINEL"] = sentinelFile.path

            let helpResult = try Self.runProcess(
                executablePath: "/bin/bash",
                arguments: [scriptPath, "--help"],
                environment: cleanEnv
            )
            #expect(helpResult.status == 0)
            #expect(helpResult.stdout.contains("Usage: ./scripts/bootstrap-fork-signing.sh [options]"))
            #expect(helpResult.stderr.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: sentinelFile.path))

            let cases: [(label: String, args: [String], expectedError: String)] = [
                (
                    "missing --repo value",
                    ["--repo"],
                    "Option --repo requires a value"
                ),
                (
                    "empty --env-name value",
                    ["--env-name", ""],
                    "Option --env-name requires a value"
                ),
                (
                    "missing --branch-policy value",
                    ["--branch-policy"],
                    "Option --branch-policy requires a value"
                ),
                (
                    "missing --cert-cn value",
                    ["--cert-cn"],
                    "Option --cert-cn requires a value"
                ),
                (
                    "missing --output-backup-dir value",
                    ["--output-backup-dir"],
                    "Option --output-backup-dir requires a value"
                ),
                (
                    "unknown option",
                    ["--bogus-option"],
                    "Unknown option: --bogus-option"
                ),
                (
                    "invalid --repo slug (missing slash)",
                    ["--dry-run", "--repo", "noslash"],
                    "Invalid --repo slug (expected OWNER/REPO)"
                ),
                (
                    "invalid --repo slug (extra slash)",
                    ["--dry-run", "--repo", "owner/repo/extra"],
                    "Invalid --repo slug (expected OWNER/REPO)"
                ),
                (
                    "invalid --env-name (slash)",
                    ["--dry-run", "--env-name", "release/prod"],
                    "Invalid --env-name"
                ),
                (
                    "invalid --branch-policy (wildcard)",
                    ["--dry-run", "--branch-policy", "fork*"],
                    "Invalid --branch-policy"
                ),
                (
                    "invalid --cert-cn (RDN slash/equals injection)",
                    ["--dry-run", "--cert-cn", "Bad/CN=Injected"],
                    "--cert-cn contains unsupported characters"
                ),
                (
                    "invalid --cert-cn (newline OpenSSL config injection)",
                    ["--dry-run", "--cert-cn", "ClipBook\n[v3_ca]\nbasicConstraints=CA:TRUE"],
                    "--cert-cn contains unsupported characters"
                ),
                (
                    "existing file at --output-backup-dir",
                    ["--dry-run", "--output-backup-dir", scriptPath],
                    "--output-backup-dir exists and is not a directory"
                ),
                (
                    "non-empty directory at --output-backup-dir",
                    ["--dry-run", "--output-backup-dir", stubBinDir.path],
                    "--output-backup-dir must be empty or not yet exist"
                )
            ]

            for testCase in cases {
                try? FileManager.default.removeItem(at: sentinelFile)
                let result = try Self.runProcess(
                    executablePath: "/bin/bash",
                    arguments: [scriptPath] + testCase.args,
                    environment: cleanEnv
                )
                #expect(result.status != 0, "Expected non-zero exit for \(testCase.label)")
                #expect(result.status != 99, "Stubbed side-effect tool was unexpectedly invoked for \(testCase.label)")
                #expect(
                    !FileManager.default.fileExists(atPath: sentinelFile.path),
                    "Bootstrap preflight must exit before gh/security/xcodebuild/mktemp for \(testCase.label)"
                )
                #expect(
                    result.stderr.contains(testCase.expectedError),
                    "Expected '\(testCase.expectedError)' in stderr for \(testCase.label), got: \(result.stderr)"
                )
            }
        }
    }

    @Test func githubWorkflowSecurityInvariantsHold() throws {
        let ciPath = Self.repoRootURL.appendingPathComponent(".github/workflows/ci.yml").path
        let releasePath = Self.repoRootURL.appendingPathComponent(".github/workflows/release.yml").path
        let syncPath = Self.repoRootURL.appendingPathComponent(".github/workflows/sync-upstream.yml").path

        let validator = #"""
        require "open3"
        require "yaml"

        ci_path, release_path, sync_path = ARGV
        workflows = {
          "ci.yml" => YAML.safe_load(File.read(ci_path), permitted_classes: [], aliases: false),
          "release.yml" => YAML.safe_load(File.read(release_path), permitted_classes: [], aliases: false),
          "sync-upstream.yml" => YAML.safe_load(File.read(sync_path), permitted_classes: [], aliases: false)
        }

        sha_pin = /\A[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+@[0-9a-f]{40}\z/

        workflows.each do |name, doc|
          abort "#{name}: root must be a mapping" unless doc.is_a?(Hash)
          triggers = doc["on"] || doc[true]
          abort "#{name}: missing triggers" unless triggers.is_a?(Hash)
          abort "#{name}: pull_request_target is forbidden" if triggers.key?("pull_request_target")
          abort "#{name}: top-level permissions must be explicit" unless doc.key?("permissions") && doc["permissions"].is_a?(Hash)

          jobs = doc["jobs"]
          abort "#{name}: missing jobs" unless jobs.is_a?(Hash) && !jobs.empty?
          jobs.each do |job_name, job|
            abort "#{name}/#{job_name}: missing timeout-minutes" unless job["timeout-minutes"].is_a?(Integer) && job["timeout-minutes"] > 0
            steps = job["steps"]
            abort "#{name}/#{job_name}: missing steps" unless steps.is_a?(Array) && !steps.empty?
            steps.each_with_index do |step, idx|
              if step.key?("uses")
                uses = step["uses"].to_s
                abort "#{name}/#{job_name} step #{idx}: unpinned uses #{uses}" unless uses.match?(sha_pin)
                if uses.start_with?("actions/checkout@")
                  persist = step.dig("with", "persist-credentials")
                  abort "#{name}/#{job_name} step #{idx}: checkout must set persist-credentials: false" unless persist == false
                end
              end
              if step.key?("run")
                run_body = step["run"].to_s
                if run_body.lines.any? { |line| !line.lstrip.start_with?("#") && line.match?(/\bset\s+(?:-[A-Za-z]*x|-o\s+xtrace)\b/) }
                  abort "#{name}/#{job_name} step #{idx}: xtrace is forbidden"
                end
              end
            end
          end
        end

        ci = workflows["ci.yml"]
        ci_triggers = ci["on"] || ci[true]
        abort "ci.yml: permissions must be contents: read" unless ci["permissions"] == { "contents" => "read" }
        abort "ci.yml: must not duplicate fork push trigger covered by release.yml" if ci_triggers.key?("push")
        abort "ci.yml: pull_request types must include ready_for_review" unless Array(ci_triggers.dig("pull_request", "types")).include?("ready_for_review")
        abort "ci.yml: jobs must not reference an environment" if ci["jobs"].each_value.any? { |j| j.key?("environment") }
        abort "ci.yml: macos-test must skip draft pull requests" unless ci.dig("jobs", "macos-test", "if") == "github.event_name != 'pull_request' || github.event.pull_request.draft == false"
        abort "ci.yml: build-and-test must run always() to prevent skipped-check bypass" unless ci.dig("jobs", "build-and-test", "if") == "always()"
        abort "ci.yml: build-and-test must depend on macos-test" unless Array(ci.dig("jobs", "build-and-test", "needs")) == ["macos-test"]
        abort "ci.yml: must not reference secrets" if YAML.dump(ci).include?("secrets.")

        rel = workflows["release.yml"]
        abort "release.yml: top-level permissions must be empty" unless rel["permissions"] == {}
        abort "release.yml: top-level env must not reference secrets" if rel.key?("env") && YAML.dump(rel["env"]).include?("secrets.")
        abort "release.yml: concurrency must not cancel in-progress releases" unless rel.dig("concurrency", "cancel-in-progress") == false
        rel_job = rel.dig("jobs", "release")
        abort "release.yml: release job must gate on refs/heads/fork" unless rel_job["if"] == "github.ref == 'refs/heads/fork'"
        abort "release.yml: release job must target release environment" unless rel_job["environment"] == "release"
        abort "release.yml: release job permissions must be contents: write" unless rel_job["permissions"] == { "contents" => "write" }
        abort "release.yml: job-level env must not reference secrets" if rel_job.key?("env") && YAML.dump(rel_job["env"]).include?("secrets.")

        secret_step_name = "Install verified rcodesign and stage ephemeral signing files"
        secret_steps = rel_job["steps"].select { |s| YAML.dump(s).include?("secrets.") }
        unless secret_steps.size == 1 && secret_steps.first["name"] == secret_step_name
          abort "release.yml: secrets.* must be scoped exclusively to step '#{secret_step_name}'"
        end
        staging_without_env = secret_steps.first.reject { |k, _| k == "env" }
        if YAML.dump(staging_without_env).include?("secrets.")
          abort "release.yml: secrets.* must only appear in step env, never interpolated in run/with"
        end

        rel_runs = rel_job["steps"].map { |s| s["run"] }.compact.join("\n")
        abort "release.yml: untrusted inputs must not be interpolated in run scripts" if rel_runs.include?("${{ inputs.")
        cleanup_step = rel_job["steps"].find { |s| s["name"] == "Remove ephemeral signing files" }
        abort "release.yml: missing always() signing cleanup step" unless cleanup_step && cleanup_step["if"] == "always()"

        ruby_parser_match = rel_runs.match(/\/usr\/bin\/ruby\s+-rrexml\/document\s+-rrexml\/security\s+-e\s+'([^']+)'/m)
        abort "release.yml: could not extract inline Ruby appcast parser" unless ruby_parser_match
        ruby_parser = ruby_parser_match[1]
        abort "release.yml: appcast parser must disable entity expansion" unless ruby_parser.include?("REXML::Security.entity_expansion_limit = 0")

        run_ruby_parser = lambda do |xml|
          Open3.capture3(
            { "PREV_XML_PATH" => "/dev/stdin" },
            "/usr/bin/ruby", "-rrexml/document", "-rrexml/security", "-e", ruby_parser,
            stdin_data: xml
          )
        end

        sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        r_out, r_err, r_st = run_ruby_parser.call(
          "<?xml version=\"1.0\" encoding=\"utf-8\"?>" \
          "<rss version=\"2.0\" xmlns:sparkle=\"#{sparkle_ns}\"><channel>" \
          "<item><sparkle:version>9</sparkle:version></item>" \
          "<item><enclosure url=\"https://example.com/a.dmg\" sparkle:version=\"10\" /></item>" \
          "</channel></rss>"
        )
        abort "release.yml parser numeric max check failed: #{r_out} #{r_err}" unless r_st.success? && r_out.strip == "10"

        r_out, r_err, r_st = run_ruby_parser.call(
          "<?xml version=\"1.0\" encoding=\"utf-8\"?>" \
          "<rss version=\"2.0\" xmlns:sparkle=\"#{sparkle_ns}\"><channel>" \
          "<item><enclosure url=\"https://example.com/a.dmg\" sparkle:version=\"1000042\" /></item>" \
          "</channel></rss>"
        )
        abort "release.yml parser attribute-only check failed: #{r_out} #{r_err}" unless r_st.success? && r_out.strip == "1000042"

        [
          "<?xml version=\"1.0\"?><!DOCTYPE rss [<!ENTITY xxe \"boom\">]><rss xmlns:sparkle=\"#{sparkle_ns}\"><channel><item><sparkle:version>1000001</sparkle:version></item></channel></rss>",
          "<?xml version=\"1.0\"?><! entity x \"y\"><rss xmlns:sparkle=\"#{sparkle_ns}\"><channel><item><sparkle:version>1000001</sparkle:version></item></channel></rss>",
          "<?xml version=\"1.0\"?><rss xmlns:sparkle=\"#{sparkle_ns}\"><channel><item><sparkle:version>2.1.0</sparkle:version></item></channel></rss>",
          "<?xml version=\"1.0\"?><rss xmlns:sparkle=\"#{sparkle_ns}\"><channel><item><sparkle:version>0</sparkle:version></item></channel></rss>",
          "<?xml version=\"1.0\"?><rss xmlns:sparkle=\"#{sparkle_ns}\"><channel></channel></rss>",
          "<rss><unclosed"
        ].each_with_index do |bad_xml, idx|
          _, _, bad_st = run_ruby_parser.call(bad_xml)
          abort "release.yml parser accepted invalid XML case #{idx}" if bad_st.success?
        end

        sync = workflows["sync-upstream.yml"]
        abort "sync-upstream.yml: top-level permissions must be empty" unless sync["permissions"] == {}
        abort "sync-upstream.yml: concurrency must not cancel in-progress sync" unless sync.dig("concurrency", "cancel-in-progress") == false
        sync_job = sync.dig("jobs", "sync")
        abort "sync-upstream.yml: sync job must not reference an environment" if sync_job.key?("environment")
        abort "sync-upstream.yml: sync permissions mismatch" unless sync_job["permissions"] == { "contents" => "write", "pull-requests" => "write" }

        sync_runs = sync_job["steps"].map { |s| s["run"] }.compact.join("\n")
        abort "sync-upstream.yml: must guard against upstream .github/workflows edits" unless sync_runs.include?(".github/workflows/")

        hp_flag = "core.hooksPath=/dev/null"
        sm_flag = "submodule.recurse=false"
        non_comment = sync_runs.lines.reject { |l| l.lstrip.start_with?("#") }.join
        cleaned_sync = non_comment.gsub(/\\\x60[^\x60$\n]*\\\x60/, "")
        git_token = /(?<![.\w-])(?:\/usr\/bin\/|command\s+)?git(?=\s)/
        hp_re = /(?:^|\s)-c\s+#{Regexp.escape(hp_flag)}(?=\s)/
        sm_re = /(?:^|\s)-c\s+#{Regexp.escape(sm_flag)}(?=\s)/

        fn_match = cleaned_sync.match(/^\s*(?:function\s+)?safe_git\s*(?:\(\))?\s*\{\s*(.*?)\s*\}/m)
        abort "sync-upstream.yml: missing safe_git() wrapper" unless fn_match
        fn_body = fn_match[1].gsub(/\\\n\s*/, " ").strip.sub(/;\s*\z/, "")
        unless fn_body.match?(/\A(?:\/usr\/bin\/|command\s+)?git(?:\s+-c\s+\S+)*\s+"\$@"\z/) &&
               fn_body.match?(hp_re) &&
               fn_body.match?(sm_re)
          abort "sync-upstream.yml: safe_git() must wrap only git with -c #{hp_flag}, -c #{sm_flag}, and \"$@\" (got: #{fn_body})"
        end
        without_fn = cleaned_sync.sub(fn_match[0], "").gsub(/\\\n\s*/, " ")
        if (bad_git = without_fn.match(/.{0,20}#{git_token}.{0,40}/))
          abort "sync-upstream.yml: bare git invocation outside safe_git() is forbidden: #{bad_git[0].strip}"
        end
        abort "sync-upstream.yml: expected safe_git invocations" unless without_fn.scan(/\bsafe_git(?=\s)/).size >= 10

        semver_fn_match = cleaned_sync.match(/^\s*(?:function\s+)?semver_gt\s*(?:\(\))?\s*\{(.*?)^\s*\}/m)
        abort "sync-upstream.yml: missing semver_gt() helper" unless semver_fn_match
        without_semver = cleaned_sync.sub(semver_fn_match[0], "")
        abort "sync-upstream.yml: dpkg is forbidden outside semver_gt()" if without_semver.include?("dpkg")
        abort "sync-upstream.yml: expected semver_gt invocations" unless without_semver.scan(/\bsemver_gt(?=\s)/).size >= 3

        semver_test_script = <<~BASH
          set -euo pipefail
          dpkg() {
            [[ "$1" == "--compare-versions" && "$2" == "--" && "$4" == "gt" ]] || exit 2
            /usr/bin/python3 -I - "$3" "$5" <<'PY'
          import sys
          def verrevcmp(a, b):
              i = j = 0
              while i < len(a) or j < len(b):
                  while (i < len(a) and not a[i].isdigit()) or (j < len(b) and not b[j].isdigit()):
                      ac = ord(a[i]) if i < len(a) and not a[i].isdigit() else 0
                      bc = ord(b[j]) if j < len(b) and not b[j].isdigit() else 0
                      if ac != bc:
                          return ac - bc
                      i += 1 if i < len(a) else 0
                      j += 1 if j < len(b) else 0
                  ia, jb = i, j
                  while i < len(a) and a[i].isdigit():
                      i += 1
                  while j < len(b) and b[j].isdigit():
                      j += 1
                  na = int(a[ia:i] or "0")
                  nb = int(b[jb:j] or "0")
                  if na != nb:
                      return na - nb
              return 0
          sys.exit(0 if verrevcmp(sys.argv[1], sys.argv[2]) > 0 else 1)
          PY
          }
          #{semver_fn_match[0]}
          ! semver_gt "2.6.0" "2.6"
          ! semver_gt "2.6" "2.6.0"
          ! semver_gt "2.5.2" "2.5.2"
          semver_gt "2.6" "2.5.2"
          semver_gt "2.10" "2.9.9"
          semver_gt "2.5.10" "2.5.2"
        BASH
        s_out, s_err, s_st = Open3.capture3("/bin/bash", "-c", semver_test_script)
        abort "sync-upstream.yml semver_gt() check failed: #{s_out} #{s_err}" unless s_st.success?

        py_parser_match = sync_runs.match(/\/usr\/bin\/python3\s+-I(?:\s+-[A-Za-z]+)*\s+-c\s+'([^']+)'/m)
        abort "sync-upstream.yml: could not extract isolated python3 -I appcast parser" unless py_parser_match
        py_parser = py_parser_match[1]

        run_py_parser = lambda do |xml|
          Open3.capture3("/usr/bin/python3", "-I", "-c", py_parser, stdin_data: xml)
        end

        p_out, p_err, p_st = run_py_parser.call(
          "<?xml version=\"1.0\" encoding=\"utf-8\"?>" \
          "<rss version=\"2.0\" xmlns:sparkle=\"#{sparkle_ns}\"><channel>" \
          "<item><sparkle:shortVersionString>1.9.9</sparkle:shortVersionString></item>" \
          "<item><enclosure url=\"https://example.com/a.dmg\" sparkle:shortVersionString=\"1.10\" /></item>" \
          "</channel></rss>"
        )
        abort "sync-upstream.yml parser semver tuple check 1 failed: #{p_out} #{p_err}" unless p_st.success? && p_out.strip == "1.10"

        p_out, p_err, p_st = run_py_parser.call(
          "<?xml version=\"1.0\" encoding=\"utf-8\"?>" \
          "<rss version=\"2.0\" xmlns:sparkle=\"#{sparkle_ns}\"><channel>" \
          "<item><sparkle:shortVersionString>2.9.9</sparkle:shortVersionString></item>" \
          "<item><sparkle:shortVersionString>2.10</sparkle:shortVersionString></item>" \
          "<item><enclosure url=\"https://example.com/a.dmg\" sparkle:shortVersionString=\"2.10.1\" /></item>" \
          "</channel></rss>"
        )
        abort "sync-upstream.yml parser semver tuple check 2 failed: #{p_out} #{p_err}" unless p_st.success? && p_out.strip == "2.10.1"

        p_out, p_err, p_st = run_py_parser.call(
          "<?xml version=\"1.0\" encoding=\"utf-8\"?>" \
          "<rss version=\"2.0\" xmlns:sparkle=\"#{sparkle_ns}\"><channel>" \
          "<item><sparkle:shortVersionString>2.6</sparkle:shortVersionString></item>" \
          "<item><enclosure url=\"https://example.com/a.dmg\" sparkle:shortVersionString=\"2.6.0\" /></item>" \
          "</channel></rss>"
        )
        abort "sync-upstream.yml parser 2-vs-3 component tie-break failed: #{p_out} #{p_err}" unless p_st.success? && p_out.strip == "2.6.0"

        oversized_xml = "<?xml version=\"1.0\"?><rss xmlns:sparkle=\"#{sparkle_ns}\"><channel><item><sparkle:shortVersionString>2.1.0</sparkle:shortVersionString></item></channel>" + (" " * 1_048_576) + "</rss>"
        [
          "",
          oversized_xml,
          "<?xml version=\"1.0\"?><!DOCTYPE rss [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><rss xmlns:sparkle=\"#{sparkle_ns}\"><channel><item><sparkle:shortVersionString>2.1.0</sparkle:shortVersionString></item></channel></rss>",
          "<?xml version=\"1.0\"?><! entity foo \"bar\"><rss xmlns:sparkle=\"#{sparkle_ns}\"><channel><item><sparkle:shortVersionString>2.1.0</sparkle:shortVersionString></item></channel></rss>",
          "<?xml version=\"1.0\"?><rss xmlns:sparkle=\"#{sparkle_ns}\"><channel><item><sparkle:shortVersionString>2.1.0-beta1</sparkle:shortVersionString></item></channel></rss>",
          "<?xml version=\"1.0\"?><rss xmlns:sparkle=\"#{sparkle_ns}\"><channel></channel></rss>",
          "<rss><broken"
        ].each_with_index do |bad_xml, idx|
          _, _, bad_st = run_py_parser.call(bad_xml)
          abort "sync-upstream.yml parser accepted invalid XML case #{idx}" if bad_st.success?
        end
        """#

        let result = try Self.runProcess(
            executablePath: "/usr/bin/ruby",
            arguments: ["-e", validator, ciPath, releasePath, syncPath]
        )
        #expect(result.status == 0, "Workflow security invariant failed: \(result.stderr)")
    }

    @Test func bootstrapForkSigningTrustParserAndLivePreflightGuardsHold() throws {
        let scriptURL = Self.repoRootURL.appendingPathComponent("scripts/bootstrap-fork-signing.sh")
        let scriptSource = try String(contentsOf: scriptURL, encoding: .utf8)

        let marker = "uv run --no-project python3 -c '"
        let startRange = try #require(scriptSource.range(of: marker))
        let afterStart = scriptSource[startRange.upperBound...]
        let endRange = try #require(afterStart.range(of: "\n'\n"))
        let trustParser = String(afterStart[..<endRange.lowerBound])

        let parserEnv = ["EXPECTED_CERT_CN": "ClipBook Fork Code Signing"]

        let validDumps = [
            """
            Number of certs: 1
            Cert 0: ClipBook Fork Code Signing
               Number of trust settings : 1
               Trust Setting 0:
                  Policy OID            : Code Signing
                  Allowed Error         : CSSMERR_TP_NOT_TRUSTED
            """,
            """
            Number of certs: 2
            Cert 0: Unrelated Root CA
               Number of trust settings : 0
            Cert 1: ClipBook Fork Code Signing
               Number of trust settings : 1
               Trust Setting 0:
                  Policy OID            : Code Signing
                  Result Type           : kSecTrustSettingsResultTrustRoot
            """
        ]

        for (index, dump) in validDumps.enumerated() {
            let result = try Self.runProcess(
                executablePath: "/usr/bin/python3",
                arguments: ["-I", "-c", trustParser],
                environment: parserEnv,
                stdinData: Data(dump.utf8)
            )
            #expect(result.status == 0, "Expected valid trust dump \(index) to pass, stderr: \(result.stderr)")
        }

        let invalidDumps: [(label: String, dump: String, expectedError: String)] = [
            (
                "deny result type",
                """
                Cert 0: ClipBook Fork Code Signing
                   Number of trust settings : 1
                   Trust Setting 0:
                      Policy OID            : Code Signing
                      Result Type           : kSecTrustSettingsResultDeny
                """,
                "disallowed Result Type: kSecTrustSettingsResultDeny"
            ),
            (
                "unspecified result type",
                """
                Cert 0: ClipBook Fork Code Signing
                   Number of trust settings : 1
                   Trust Setting 0:
                      Policy OID            : Code Signing
                      Result Type           : kSecTrustSettingsResultUnspecified
                """,
                "disallowed Result Type: kSecTrustSettingsResultUnspecified"
            ),
            (
                "blanket trust (0 settings)",
                """
                Cert 0: ClipBook Fork Code Signing
                   Number of trust settings : 0
                """,
                "must contain exactly 1 trust setting"
            ),
            (
                "SSL policy instead of Code Signing",
                """
                Cert 0: ClipBook Fork Code Signing
                   Number of trust settings : 1
                   Trust Setting 0:
                      Policy OID            : SSL
                """,
                "not scoped to Code Signing policy"
            ),
            (
                "duplicate CN stanzas",
                """
                Cert 0: ClipBook Fork Code Signing
                   Number of trust settings : 1
                   Trust Setting 0:
                      Policy OID            : Code Signing
                Cert 1: ClipBook Fork Code Signing
                   Number of trust settings : 1
                   Trust Setting 0:
                      Policy OID            : Code Signing
                """,
                "Expected exactly 1 trust stanza"
            ),
            (
                "missing CN stanza",
                """
                Cert 0: Some Other Cert
                   Number of trust settings : 1
                   Trust Setting 0:
                      Policy OID            : Code Signing
                """,
                "Expected exactly 1 trust stanza"
            )
        ]

        for testCase in invalidDumps {
            let result = try Self.runProcess(
                executablePath: "/usr/bin/python3",
                arguments: ["-I", "-c", trustParser],
                environment: parserEnv,
                stdinData: Data(testCase.dump.utf8)
            )
            #expect(result.status != 0, "Expected invalid trust dump '\(testCase.label)' to fail")
            #expect(
                result.stderr.contains(testCase.expectedError),
                "Expected '\(testCase.expectedError)' for '\(testCase.label)', got: \(result.stderr)"
            )
        }

        // Verify live-mode preflight aborts before mktemp or mutating repo files when admin check or
        // pre-existing keychain certificate check fails.
        let infoPlistURL = Self.repoRootURL.appendingPathComponent("ClipBook/Info.plist")
        let publicCertURL = Self.repoRootURL.appendingPathComponent("scripts/ClipBookForkCodeSigning.crt")
        let baselineInfoPlist = try Data(contentsOf: infoPlistURL)
        let baselinePublicCert = try Data(contentsOf: publicCertURL)

        try TestSupport.withTemporaryDirectory { tempDir in
            let stubBinDir = tempDir.appendingPathComponent("stub-bin", isDirectory: true)
            let sentinelFile = tempDir.appendingPathComponent("post-preflight.invoked")
            try Self.installSentinelStubTools(named: ["mktemp", "xcodebuild"], in: stubBinDir)

            let uvStub = stubBinDir.appendingPathComponent("uv")
            try Data("#!/bin/bash\nexit 0\n".utf8).write(to: uvStub)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uvStub.path)

            let ghStub = stubBinDir.appendingPathComponent("gh")
            let ghScript = """
            #!/bin/bash
            printf '%s\\n' "${STUB_GH_ADMIN:-false}"
            """
            try Data(ghScript.utf8).write(to: ghStub)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ghStub.path)

            let securityStub = stubBinDir.appendingPathComponent("security")
            let securityScript = """
            #!/bin/bash
            if [[ "${1:-}" == "find-certificate" ]]; then
              printf '%s' "${STUB_EXISTING_CERT:-}"
              exit 0
            fi
            exit 0
            """
            try Data(securityScript.utf8).write(to: securityStub)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: securityStub.path)

            var env = ProcessInfo.processInfo.environment
            let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = "\(stubBinDir.path):\(basePath)"
            env["STUB_INVOKED_SENTINEL"] = sentinelFile.path

            env["STUB_GH_ADMIN"] = "false"
            let nonAdminResult = try Self.runProcess(
                executablePath: "/bin/bash",
                arguments: [scriptURL.path],
                environment: env
            )
            #expect(nonAdminResult.status != 0 && nonAdminResult.status != 99)
            #expect(nonAdminResult.stderr.contains("does not have admin permissions"))
            #expect(!FileManager.default.fileExists(atPath: sentinelFile.path))

            env["STUB_GH_ADMIN"] = "true"
            env["STUB_EXISTING_CERT"] = "SHA-1 hash: 0123456789ABCDEF0123456789ABCDEF01234567\n"
            let existingCertResult = try Self.runProcess(
                executablePath: "/bin/bash",
                arguments: [scriptURL.path],
                environment: env
            )
            #expect(existingCertResult.status != 0 && existingCertResult.status != 99)
            #expect(existingCertResult.stderr.contains("already exists in"))
            #expect(!FileManager.default.fileExists(atPath: sentinelFile.path))

            #expect(try Data(contentsOf: infoPlistURL) == baselineInfoPlist)
            #expect(try Data(contentsOf: publicCertURL) == baselinePublicCert)
        }
    }

    @Test
    func releaseForkVerifySignedTargetHandlesUnquotedAndQuotedCsreqIdentifiers() throws {
        let scriptURL = Self.repoRootURL.appendingPathComponent("scripts/release-fork.sh")
        let scriptText = try String(contentsOf: scriptURL, encoding: .utf8)

        let helperStart = try #require(scriptText.range(of: "assert_runtime_and_authority() {")?.lowerBound)
        let helperEnd = try #require(
            scriptText.range(of: "\nverify_signed_target \"$STAGED_APP\"")?.lowerBound
        )
        let extractedFunctions = String(scriptText[helperStart..<helperEnd])
            .replacingOccurrences(of: "/usr/bin/codesign", with: "codesign")

        try TestSupport.withTemporaryDirectory { tempDir in
            let leafSHA1 = "d8190d8f86de555ccea7f5008e49dfd8b6c1dd8a"

            func decompiledCsreq(for identifier: String) throws -> String {
                let blobURL = tempDir.appendingPathComponent("\(identifier).csreq")
                let reqSpec = "identifier \"\(identifier)\" and certificate leaf = H\"\(leafSHA1)\"\n"
                let compile = try Self.runProcess(
                    executablePath: "/usr/bin/csreq",
                    arguments: ["-r-", "-b", blobURL.path],
                    stdinData: Data(reqSpec.utf8)
                )
                #expect(compile.status == 0)
                let decompile = try Self.runProcess(
                    executablePath: "/usr/bin/csreq",
                    arguments: ["-r", blobURL.path, "-t"]
                )
                #expect(decompile.status == 0)
                return decompile.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let autoupdateDR = try decompiledCsreq(for: "Autoupdate")
            let appDR = try decompiledCsreq(for: "com.ikryanov.clipbook.v2")
            #expect(autoupdateDR.contains("identifier Autoupdate "))
            #expect(!autoupdateDR.contains("identifier \"Autoupdate\""))
            #expect(appDR.contains("identifier \"com.ikryanov.clipbook.v2\""))

            let stubBin = tempDir.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: stubBin, withIntermediateDirectories: true)
            let codesignStub = stubBin.appendingPathComponent("codesign")
            let codesignScript = """
            #!/bin/bash
            if [[ "${1:-}" == "-dvvv" ]]; then
              printf 'Identifier=%s\\nCodeDirectory v=20500 size=1024 flags=0x10000(runtime)\\nAuthority=ClipBook CI Smoke Signing\\nSealed Resources version=2 rules=13 files=1\\n' "$STUB_ACTUAL_ID"
              exit 0
            fi
            if [[ "${1:-}" == "-dr" ]]; then
              printf 'designated => %s\\n' "$STUB_DR_TEXT"
              exit 0
            fi
            if [[ "${1:-}" == "-d" && "${2:-}" == "--entitlements" ]]; then
              exit 0
            fi
            exit 1
            """
            try Data(codesignScript.utf8).write(to: codesignStub)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codesignStub.path)

            let harnessURL = tempDir.appendingPathComponent("verify-harness.sh")
            let harnessScript = """
            #!/bin/bash
            set -euo pipefail
            USES_ADHOC_SIGNING=0
            SMOKE_TEST=1
            EXPECTED_AUTHORITY="ClipBook CI Smoke Signing"
            P12_FILE="/nonexistent/smoke.p12"
            LEAF_SHA1="\(leafSHA1)"
            REPO_CERT_SHA1="\(leafSHA1)"
            EFFECTIVE_SIGNING_IDENTITY="-"
            WORK_DIR="\(tempDir.path)"
            \(extractedFunctions)
            verify_signed_target "$1" "$2" "$3" 0
            """
            try Data(harnessScript.utf8).write(to: harnessURL)

            var env = ProcessInfo.processInfo.environment
            let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = "\(stubBin.path):\(basePath)"

            // Single-token identifier ("Autoupdate") emitted without quotes by Apple csreq/codesign.
            env["STUB_ACTUAL_ID"] = "Autoupdate"
            env["STUB_DR_TEXT"] = autoupdateDR
            let autoupdatePass = try Self.runProcess(
                executablePath: "/bin/bash",
                arguments: [harnessURL.path, "/stub/Autoupdate", "Autoupdate", "0"],
                environment: env
            )
            #expect(autoupdatePass.status == 0, "\(autoupdatePass.stderr)")

            // Dotted bundle identifier ("com.ikryanov.clipbook.v2") emitted with quotes.
            env["STUB_ACTUAL_ID"] = "com.ikryanov.clipbook.v2"
            env["STUB_DR_TEXT"] = appDR
            let appPass = try Self.runProcess(
                executablePath: "/bin/bash",
                arguments: [harnessURL.path, "/stub/ClipBook.app", "com.ikryanov.clipbook.v2", "1"],
                environment: env
            )
            #expect(appPass.status == 0, "\(appPass.stderr)")

            // Prefix mismatch ("AutoupdateHelper" vs expected "Autoupdate") must fail closed.
            let prefixMismatchDR = try decompiledCsreq(for: "AutoupdateHelper")
            env["STUB_ACTUAL_ID"] = "Autoupdate"
            env["STUB_DR_TEXT"] = prefixMismatchDR
            let prefixFail = try Self.runProcess(
                executablePath: "/bin/bash",
                arguments: [harnessURL.path, "/stub/Autoupdate", "Autoupdate", "0"],
                environment: env
            )
            #expect(prefixFail.status != 0)
            #expect(prefixFail.stderr.contains("Designated requirement missing identifier"))
        }
    }
}
