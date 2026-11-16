import AppKit
@testable import ClipBook
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
        #expect(publicEDKey != "oQDl3fpWpRKjRpG5Dkyt3iE7uFGw8Xu6/cL1W5oeFTc=", "SUPublicEDKey must be the fork key, not upstream's")

        let expandedDefaultsDomain = Bundle.main.object(forInfoDictionaryKey: "SUDefaultsDomain") as? String
        #expect(expandedDefaultsDomain == "com.ikryanov.clipbook.v2.debug.fork.sparkle")
    }

    @Test func publicCodeSigningCertificateParsesWithForkCommonName() throws {
        let certURL = Self.repoRootURL.appendingPathComponent("scripts/ClipBookForkCodeSigning.crt")
        let pem = try String(contentsOf: certURL, encoding: .utf8)
        #expect(!pem.contains("PRIVATE KEY"))

        let pemBody = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        let derData = try #require(Data(base64Encoded: pemBody, options: .ignoreUnknownCharacters))
        #expect(!derData.isEmpty)

        let certificate = try #require(SecCertificateCreateWithData(nil, derData as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "ClipBook Fork Code Signing")
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

    @Test func githubWorkflowSecurityInvariantsHold() throws {
        let ciPath = Self.repoRootURL.appendingPathComponent(".github/workflows/ci.yml").path
        let releasePath = Self.repoRootURL.appendingPathComponent(".github/workflows/release.yml").path
        let syncPath = Self.repoRootURL.appendingPathComponent(".github/workflows/sync-upstream.yml").path

        let validator = #"""
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
        abort "ci.yml: permissions must be contents: read" unless ci["permissions"] == { "contents" => "read" }

        rel = workflows["release.yml"]
        abort "release.yml: top-level permissions must be empty" unless rel["permissions"] == {}
        abort "release.yml: concurrency must not cancel in-progress releases" unless rel.dig("concurrency", "cancel-in-progress") == false
        rel_job = rel.dig("jobs", "release")
        abort "release.yml: release job must gate on refs/heads/fork" unless rel_job["if"] == "github.ref == 'refs/heads/fork'"
        abort "release.yml: release job must target release environment" unless rel_job["environment"] == "release"
        abort "release.yml: release job permissions must be contents: write" unless rel_job["permissions"] == { "contents" => "write" }
        rel_runs = rel_job["steps"].map { |s| s["run"] }.compact.join("\n")
        abort "release.yml: untrusted inputs must not be interpolated in run scripts" if rel_runs.include?("${{ inputs.")
        abort "release.yml: appcast parser must disable entity expansion" unless rel_runs.include?("REXML::Security.entity_expansion_limit = 0")
        abort "release.yml: appcast parser must reject DOCTYPE/ENTITY" unless rel_runs.include?("DOCTYPE|ENTITY")
        cleanup_step = rel_job["steps"].find { |s| s["name"] == "Remove ephemeral signing files" }
        abort "release.yml: missing always() signing cleanup step" unless cleanup_step && cleanup_step["if"] == "always()"

        sync = workflows["sync-upstream.yml"]
        abort "sync-upstream.yml: top-level permissions must be empty" unless sync["permissions"] == {}
        abort "sync-upstream.yml: concurrency must not cancel in-progress sync" unless sync.dig("concurrency", "cancel-in-progress") == false
        sync_job = sync.dig("jobs", "sync")
        abort "sync-upstream.yml: sync permissions mismatch" unless sync_job["permissions"] == { "contents" => "write", "pull-requests" => "write" }
        sync_runs = sync_job["steps"].map { |s| s["run"] }.compact.join("\n")
        abort "sync-upstream.yml: git commands must disable hooks and submodules" unless sync_runs.include?("core.hooksPath=/dev/null") && sync_runs.include?("submodule.recurse=false")
        abort "sync-upstream.yml: must guard against upstream .github/workflows edits" unless sync_runs.include?(".github/workflows/")
        abort "sync-upstream.yml: python3 must run isolated (-I) and reject DOCTYPE/ENTITY" unless sync_runs.include?("python3 -I") && sync_runs.include?("DOCTYPE|ENTITY")
        """#

        let result = try Self.runProcess(
            executablePath: "/usr/bin/ruby",
            arguments: ["-ryaml", "-e", validator, ciPath, releasePath, syncPath]
        )
        #expect(result.status == 0, "Workflow security invariant failed: \(result.stderr)")
    }
}
