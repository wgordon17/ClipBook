# ClipBook

ClipBook is a clipboard manager for macOS.

## Requirements

- macOS 13.0 or later
- Xcode with the macOS SDK

## Development

To build ClipBook and launch it, run the following command in the root directory of the project:

```bash
./run.sh
```

The app is built into `DerivedData/Debug` and relaunched, replacing the instance
the script started previously. A copy installed in `/Applications` is left
running, so a rebuild never quits the ClipBook you use day to day.

Useful options:

| Option | Description |
| --- | --- |
| `--configuration NAME` | Build configuration. Default: `Debug`. |
| `--clean` | Clean the build before rebuilding. |
| `--build-only` | Build without launching the app. |
| `--foreground` | Run the app in the terminal, streaming its output. `Ctrl+C` quits. |
| `-h`, `--help` | Show all options. |

Build output is piped through [xcbeautify](https://github.com/cpisciotta/xcbeautify)
or [xcpretty](https://github.com/xcpretty/xcpretty) when either is installed, and
falls back to the raw `xcodebuild` log otherwise.

### Tests

To run the test suite:

```bash
./test.sh
```

Options:

| Option | Description |
| --- | --- |
| `--filter IDENTIFIER` | Run only the given test suite or test, for example `DomainAndSensitiveContentTests`. Repeat to run several. A suite inside another type is named by its path, as in `DomainAndSensitiveContentTests/SensitiveContentTests`, and a single test needs its parentheses, as in `Suite/test()`. The run fails when an identifier matches no test. |
| `--no-parallel` | Run tests serially. |
| `--clean` | Clean the build before running. |
| `--record-snapshots` | Re-record the reference images in `ClipBookTests/Snapshots/macOS-<major>`. |
| `-h`, `--help` | Show all options. |

Set `RESULT_BUNDLE_PATH=PATH` to write the `.xcresult` bundle, including test
attachments such as view snapshots, to `PATH`. The path must not exist yet.
Set `SNAPSHOT_EXPORT_DIR=PATH` to export rendered PNGs for recorded, failed, or
unrecorded-OS view snapshots under `PATH/macOS-<major>/`.

The view snapshot tests compare rendered views with per-OS reference images in
`ClipBookTests/Snapshots/macOS-<major>` (named `macOS-<major>-<scenario>.png`).
After an intentional UI change, run `./test.sh --record-snapshots` (it re-records
every image for the current macOS major version and reports each one as a failure),
review the image diff, and commit the new images. A snapshot that fails attaches
the rendered image, and a diff when the sizes match, to the test result. When a
macOS major version has no directory under `ClipBookTests/Snapshots` yet, the
tests verify that each view renders to a non-empty bitmap without failing the run.

## Release

To build a signed and notarized release, run the following command in the root
directory of the project:

```bash
./release.sh --version 2.0.0
```

This archives a universal binary, packages it as a DMG, notarizes it, and updates
the Sparkle appcast under `Releases`. Notarization needs a `notarytool` keychain
profile; pass `--skip-notarization` to produce local artifacts without one. Run
`./release.sh --help` for the full list of options.

## Custom Fork Build, Auto-Updates & Upstream Interoperability

This fork (`wgordon17/ClipBook`) builds on upstream `vladimir-ikryanov/ClipBook`, adding `GRDB.swift v7.12.0` + Apple `CryptoKit` encryption at rest (`History.sqlite` `v5` normalized schema) while preserving 100% wire compatibility for preferences (`"ClipBookPreferencesV2"`, `"ClipBookForkPreferencesV1"`) and unencrypted `formatVersion = 1` `.clipbookarchive` exports, and publishing self-signed, Sparkle-updated universal macOS builds from the `fork` trunk.

### Branch Layout & Upstream Sync Workflow

- **`fork` (default protected release trunk):** Carries merged improvements, contract tests, and fork release automation. Protected by an active GitHub Repository Ruleset (`allowed_merge_methods: ["merge"]`) so two-parent merge commits preserve `upstream/main` ancestry.
- **`main` (pure upstream mirror):** Fast-forwarded to `vladimir-ikryanov/ClipBook:main` without fork-only commits.
- **Automated upstream sync (`.github/workflows/sync-upstream.yml`):** Runs weekly (Mondays 09:17 UTC) and via `workflow_dispatch` on `ubuntu-latest` with zero repository code or git hook execution. It mirrors `upstream/main` to `main`, checks upstream's appcast for `FORK_UPSTREAM_VERSION` updates, fails closed if upstream modifies `.github/workflows/`, and opens or updates a **draft** PR (`chore/sync-upstream` -> `fork`). Marking that draft PR **Ready for review** in GitHub triggers `ci.yml` (`build-and-test`), and merging it with a merge commit triggers `release.yml`.

### Initial Install, Secondary-Mac Trust & Sparkle Auto-Updates

Fork releases are signed inside-out with Hardened Runtime using a constrained self-signed X.509 `codeSigning` certificate (`CA:FALSE`) and explicit `/usr/bin/csreq` Designated Requirements (`certificate leaf = H"<sha1>"`), and verified via Ed25519-signed Sparkle 2.9.3 feeds (`SURequireSignedFeed = true`, `SUVerifyUpdateBeforeExtraction = true`).

On a Mac installing the fork build for the first time:

1. Trust the repository's public code-signing certificate strictly for the macOS Code Signing policy (`-p codeSign`):
   ```bash
   security add-trusted-cert -r trustRoot -p codeSign \
     -k ~/Library/Keychains/login.keychain-db \
     scripts/ClipBookForkCodeSigning.crt
   ```
2. After copying the first browser-downloaded `ClipBook.app` into `/Applications`, clear browser quarantine once:
   ```bash
   xattr -cr /Applications/ClipBook.app
   ```

Subsequent updates delivered through **Check for Updates...** (or background Sparkle checks against `https://github.com/wgordon17/ClipBook/releases/latest/download/appcast.xml`) verify both the feed and `.dmg` Ed25519 signatures before extraction, strip quarantine automatically, and preserve macOS Accessibility TCC across updates.

### Fork Packaging & Maintainer Signing Bootstrap

Upstream `./release.sh` remains untouched for Apple Developer ID + notarization builds. Fork builds use dedicated scripts under `scripts/`:

- **Local unprivileged smoke-test build** (archives Release, signs inside-out with Hardened Runtime, builds a compressed UDZO `.dmg`, and generates + verifies a Sparkle `appcast.xml` without touching `login.keychain-db`):
  ```bash
  ./scripts/release-fork.sh --run-number 1 --arch-list "$(uname -m)" --smoke-test --output-dir .build/release-smoke
  ```
- **Headless CI release build (`.github/workflows/release.yml`):** Uses SHA-256-verified `apple-codesign` (`rcodesign` `0.29.0`) + `/usr/bin/csreq` in user space so macOS 15+ SIP `trustd` restrictions on ephemeral runners never block signing, verifies leaf certificate `CN` authority, Hardened Runtime flags, Designated Requirements, and entitlements across all 6 Mach-O targets, and publishes `ClipBook-<version>-fork.<run>.dmg` (`CFBundleShortVersionString = <version>+fork.<run>`, `CFBundleVersion = 1000000 + <run>`) and `appcast.xml` atomically to GitHub Releases.

  `./scripts/release-fork.sh` options:

  | Option | Description |
  | --- | --- |
  | `--run-number N` | Required positive integer CI/release run number (`CFBundleVersion = 1000000 + N`). |
  | `--upstream-version X.Y.Z` | Upstream version baseline. Default: contents of `FORK_UPSTREAM_VERSION`. |
  | `--signing-identity ID` | macOS `codesign` identity when not using `--p12-file` or `--smoke-test`. Default: `ClipBook Fork Code Signing`. |
  | `--keychain PATH` | Optional keychain passed to macOS `codesign`. |
  | `--p12-file PATH` | Headless PKCS#12 bundle path for `rcodesign` mode (requires `--p12-password-file` and `--rcodesign-bin`). |
  | `--p12-password-file PATH` | File containing the PKCS#12 passphrase (`0600`). |
  | `--rcodesign-bin PATH` | Path to SHA-256-verified `apple-codesign` `rcodesign` binary. |
  | `--ed-key-file PATH` | File containing the 32-byte Base64 Sparkle Ed25519 private seed. |
  | `--derived-data-path DIR` | Xcode `DerivedData` directory. Default: `DerivedData/Release`. |
  | `--repo OWNER/REPO` | GitHub repository slug. Default: `wgordon17/ClipBook`. |
  | `--previous-build INT` | Optional monotonic `CFBundleVersion` floor (`BUILD_NUMBER` must exceed `INT`). |
  | `--output-dir DIR` | Output root directory for artifacts and `release-metadata.env`. Default: `Releases/fork`. |
  | `--arch-list "arm64 x86_64"` | Space-separated architectures to archive and verify. Default: `arm64 x86_64`. |
  | `--sign-and-verify-app APP_PATH` | Sign inside-out (Hardened Runtime) and verify an existing `ClipBook.app` bundle in place (supports `SIGNING_IDENTITY=-` ad-hoc and `--p12-file` + `--p12-password-file` + `--rcodesign-bin` modes). |
  | `--smoke-test` | Local/CI unprivileged verification mode (ephemeral Ed25519 keypair; ad-hoc Hardened Runtime unless `--p12-file` is also supplied). |
  | `-h`, `--help` | Show all options. |

- **One-time maintainer signing & GitHub Environment bootstrap** (supports `--dry-run` for offline verification):
  ```bash
  ./scripts/bootstrap-fork-signing.sh --output-backup-dir ~/.clipbook-fork-signing-backup
  ```
  Generates the 3072-bit RSA `codeSigning` PKCS#12 bundle and 32-byte Sparkle Ed25519 seed, locks and verifies the `fork`-only deployment branch policy on the `release` GitHub Environment before mutating repo files or `login.keychain-db`, writes public `scripts/ClipBookForkCodeSigning.crt` and `ClipBook/Info.plist` `SUPublicEDKey`, trusts only the public certificate locally for `-p codeSign`, uploads the signing secrets to the `release` GitHub Environment, and only then writes the `0700`/`0600` backup bundle (excluded from Spotlight and Time Machine before writing keys). Import the backup directory into an encrypted offline vault (such as 1Password) and delete the plaintext directory immediately afterward.

  `./scripts/bootstrap-fork-signing.sh` options:

  | Option | Description |
  | --- | --- |
  | `--repo OWNER/REPO` | GitHub repository slug. Default: `wgordon17/ClipBook`. |
  | `--env-name NAME` | GitHub Environment name. Default: `release`. |
  | `--branch-policy PATTERN` | Exclusive allowed deployment branch name verified on the Environment. Default: `fork`. |
  | `--cert-cn NAME` | Code-signing certificate Common Name. Default: `ClipBook Fork Code Signing`. |
  | `--output-backup-dir DIR` | Write a `0700`/`0600` Spotlight- and Time Machine-excluded backup bundle. |
  | `--skip-local-trust` | Skip installing `-p codeSign` trust in `~/Library/Keychains/login.keychain-db`. |
  | `--dry-run` | Generate and verify artifacts in a temporary workspace without modifying repo files, Keychain, or GitHub. |
  | `-h`, `--help` | Show all options. |

### Upstream Interoperability & TCC Reset

Fork and Upstream builds interoperate cleanly across preferences and archives while failing closed against accidental cross-version database corruption:

- **One-way `History.sqlite` (`v5`) clean-room schema:** On first launch, Fork migrates legacy `History.sqlite` (`v0`–`v4`) via a two-phase clean-room cutover (`History.v5.migrating.sqlite`, `0600`) to `PRAGMA user_version = 5` (`tags`, `clips`, `clip_contents`, `clip_tags`, `store_metadata`) and intentionally omits `clips.payload`. If an older or Upstream binary opens a `v5` database, `SELECT ... payload FROM clips` fails statement preparation cleanly rather than returning empty rows and triggering Upstream's `removeOrphanedStoredFiles()` deletion sweep over `Images/` and `LinkPreviews/`. To transfer history back to an Upstream build, export an unencrypted (`formatVersion = 1`) `.clipbookarchive` from Settings -> Import & Export (or offline via `./scripts/recover-history.swift`).
- **Wire-compatible preferences & `v1` archives:** `UserDefaults` key `"ClipBookPreferencesV2"` (`AppPreferences`) and unencrypted `formatVersion = 1` `.clipbookarchive` exports (`manifest.json`, `tags.json`, `history.json`, and decrypted `assets/`) remain 100% wire-compatible with upstream `vladimir-ikryanov/ClipBook`.
- **Reboot detection compatibility:** Fork reads and writes `"ClipBookLastKnownKernelBootTime"` (`kern.boottime`) while keeping `"ClipBookLastKnownBootTime"` (`Date() - systemUptime`) warm so `clearHistoryOnReboot` works seamlessly across switches in either direction.
- **Isolated fork sidecars:** Fork-specific preferences use `"ClipBookForkPreferencesV1"` (`ForkPreferences`), fork-specific files live under `~/Library/Application Support/ClipBook2/Fork/` (outside `Images/` and `LinkPreviews/`), and Sparkle state uses `SUDefaultsDomain = $(PRODUCT_BUNDLE_IDENTIFIER).fork.sparkle`.
- **Accessibility TCC when switching binary families:** Because Upstream (Apple Developer ID) and Fork (`ClipBook Fork Code Signing`) have different code-signing Designated Requirements for `com.ikryanov.clipbook.v2`, reset Accessibility permission once whenever replacing `/Applications/ClipBook.app` with the other build family:
  ```bash
  tccutil reset Accessibility com.ikryanov.clipbook.v2
  ```

### Encrypted Storage, Debug Isolation & Offline Recovery

- **`GRDB.swift v7.12.0` + `CryptoKit` encryption at rest:**
  - `GRDBHistoryStore` runs on a WAL-mode `DatabasePool` (`auto_vacuum = INCREMENTAL`, `secure_delete = ON`, `trusted_schema = OFF`, `cell_size_check = ON`, `temp_store = MEMORY`) with lazy `clip_contents` offloading (`text`, `qrCodeText`, `rtf`, `html`) so resident `AppModel` headers keep full bodies out of idle RAM and hydrate on demand (`searchQueue` incremental donor reuse for search).
  - Certificate-signed Release builds store a 256-bit master key (encoded as 64 lowercase hex ASCII bytes) in `~/Library/Keychains/login.keychain-db` (`kSecClassGenericPassword`, service `com.ikryanov.clipbook.v2.encryption`, account `master-key-v1`, `kSecAttrSynchronizable = false`) and derive four domain-separated 256-bit `HKDF<SHA256>` subkeys (`dbColumnAEADKey`, `assetFileAEADKey`, `contentKeyHMACKey`, `keyVerifierHMACKey`, verified at startup against `store_metadata` `'key_verifier_v1'`).
  - Whenever `SensitiveContent.shouldEncryptAtRest` holds (explicit `.sensitive` mark, concealed clipboard types, or detected credentials/tokens/`otpauth://`/`WIFI:` QR payloads across untruncated `text`, `qrCodeText`, `html`, `rtfData`, `title`, `linkPreviewDetails`, or `filePaths`), all 11 sensitive `clips` and `clip_contents` columns are sealed with `0x01` + `AES-256-GCM` authenticated against `columnAAD(table:column:clipID:)`, and managed external assets under `Images/*.enc` and `LinkPreviews/*.enc` are sealed with `"CBENC01\0"` + `AES-256-GCM` authenticated against `assetAAD(role:clipID:)`.
  - **Zero-plaintext screenshot staging:** New `.image` captures are written immediately as `0600` `Images/<id>.enc` before background Vision OCR runs on in-memory PNG bytes; once OCR finishes, secret or concealed captures stay encrypted (or purge immediately under `dontSave`) while benign captures demote cleanly to `.png`.
- **Development & ad-hoc Release storage isolation (`ClipBook2-Debug/`):**
  - `AppDirectories.usesIsolatedDebugStorage` inspects the running process via `SecCodeCopySigningInformation` and routes both `#if DEBUG` builds (`com.ikryanov.clipbook.v2.debug`) and any unsigned or ad-hoc `-configuration Release` build (for example `CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=-`, `./run.sh --configuration Release`, or `./scripts/release-fork.sh --smoke-test`) to `~/Library/Application Support/ClipBook2-Debug/` with a local `0600` `.devkey` (`FileDatabaseKeyProvider`). Local non-certificate builds never migrate production `~/Library/Application Support/ClipBook2/` or write `cdhash:`-pinned items into `login.keychain-db`.
- **Unencrypted (`v1`) vs passphrase-encrypted (`v2`) `.clipbookarchive` exports:**
  - Unencrypted exports produce Upstream-compatible `formatVersion = 1` bundles (prompting first when history contains sensitive items so you can encrypt, skip sensitive items, or confirm plaintext export).
  - Passphrase-encrypted exports produce `formatVersion = 2` bundles backed by `600,000`-iteration `PBKDF2-HMAC-SHA256` (Unicode NFC passphrase) + `HKDF<SHA256>` and `"CBARC02\0"` `AES-256-GCM` over `tags.json.enc`, `history.json.enc` (with `expectedAssets` 64-hex SHA-256 inventory), and `assets/**/*.enc` authenticated against `SHA256(manifest.json)`.
- **Offline emergency recovery (`./scripts/recover-history.swift`):**
  - Standalone zero-dependency Swift CLI (`CommonCrypto`, `CryptoKit`, `Darwin`, `Foundation`, `Security`, `SQLite3`) that decrypts either a local `v5` support directory (Mode A, replaying uncheckpointed `-wal` frames inside an ephemeral `0700` temp directory without modifying `--support-dir`) or a `formatVersion = 2` `.clipbookarchive` (Mode B) into a standard `formatVersion = 1` `.clipbookarchive` (`0700` directories, `0600` files).
  - **macOS GUI Terminal session (Mode A):** Queries `login.keychain-db` directly via `SecItemCopyMatching` (prompting through macOS `SecurityAgent`), or reads `<support-dir>/.devkey` automatically for `ClipBook2-Debug`:
    ```bash
    ./scripts/recover-history.swift \
      --support-dir ~/Library/Application\ Support/ClipBook2 \
      --output-dir ~/Desktop/Recovered.clipbookarchive
    ```
    Pass `--include-trashed` to also recover trashed items into `trashed-history.json`, or `--strict` to abort with exit `1` instead of isolating corrupt rows into `corrupted-items.json` (exit `2`).
  - **Headless / SSH session (Mode A):** Without WindowServer, `SecurityAgent` cannot present an interactive ACL dialog, and native `SecItemAdd` items omit `apple-tool:` from `CSSM_ACL_AUTHORIZATION_PARTITION_ID` (`65538`), causing bare `security find-generic-password -w` to fail with `errSecInteractionNotAllowed` (`-25308`). Unlock `login.keychain-db`, update the item's partition list (`-S` replaces the item's partition list; omit `-k` so `security` prompts on the SSH TTY without exposing your keychain password in `ps`), and pipe the 64-hex key into `--key-hex-stdin`:
    ```bash
    security unlock-keychain ~/Library/Keychains/login.keychain-db
    security set-generic-password-partition-list \
      -s com.ikryanov.clipbook.v2.encryption \
      -a master-key-v1 \
      -S "apple-tool:,apple:,unsigned:" \
      ~/Library/Keychains/login.keychain-db
    security find-generic-password \
      -s com.ikryanov.clipbook.v2.encryption \
      -a master-key-v1 \
      -w ~/Library/Keychains/login.keychain-db \
      | ./scripts/recover-history.swift \
          --support-dir ~/Library/Application\ Support/ClipBook2 \
          --key-hex-stdin \
          --output-dir ~/Desktop/Recovered.clipbookarchive
    ```
  - **Passphrase-encrypted `v2` `.clipbookarchive` recovery (Mode B):** Prompts on `/dev/tty` with terminal echo disabled (or accepts `--passphrase-file <path>` / `--passphrase-stdin`):
    ```bash
    ./scripts/recover-history.swift \
      --archive ~/Desktop/Backup.clipbookarchive \
      --output-dir ~/Desktop/Recovered.clipbookarchive
    ```

## License

ClipBook’s source code is provided for transparency and personal use. However, its use in commercial or redistributed products is restricted without a license. Please refer to the [LICENSE](LICENSE.md) file for details.

## Terms of Use

By using ClipBook, you agree to the [Terms of Use](https://clipbook.app/terms/) and [Privacy Policy](https://clipbook.app/privacy/).

## Support

For questions or support, please [contact me](mailto:vladimir.ikryanov@clipbook.app).
