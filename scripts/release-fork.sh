#!/usr/bin/env bash
# Never enable `set -x` in this script: private signing material is handled in memory/stdin.
set -euo pipefail

FALLBACK_ED_PRIVKEY="${SPARKLE_ED25519_PRIVATE_KEY:-}"
unset SPARKLE_ED25519_PRIVATE_KEY
for rc_var in $(compgen -v RCODESIGN_ || true); do
  unset "$rc_var"
done
unset rc_var
EFFECTIVE_ED_PRIVKEY=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ClipBook.xcodeproj"
SCHEME="ClipBook"
CONFIGURATION="Release"
APP_NAME="ClipBook"
UPSTREAM_PUBLIC_ED_KEY="oQDl3fpWpRKjRpG5Dkyt3iE7uFGw8Xu6/cL1W5oeFTc="
ENTITLEMENTS_PATH="$ROOT_DIR/scripts/ClipBookForkRelease.entitlements"

RUN_NUMBER=""
UPSTREAM_VERSION=""
SIGNING_IDENTITY="${SIGNING_IDENTITY:-ClipBook Fork Code Signing}"
KEYCHAIN_PATH="${KEYCHAIN_PATH:-}"
P12_FILE=""
P12_PASSWORD_FILE=""
SIGNER_BIN=""
ED_KEY_FILE=""
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/DerivedData/Release}"
REPO="wgordon17/ClipBook"
PREVIOUS_BUILD=""
OUTPUT_DIR="$ROOT_DIR/Releases/fork"
APP_ARCHS_EXPLICIT=0
if [[ -n "${APP_ARCHS+x}" ]]; then
  APP_ARCHS_EXPLICIT=1
fi
APP_ARCHS="${APP_ARCHS:-arm64 x86_64}"
SMOKE_TEST=0
SIGN_AND_VERIFY_APP=""
SPARKLE_CACHE_STAGE_DIR=""
VERIFY_SCRATCH_DIR=""

cleanup_release_fork() {
  if [[ -n "${SPARKLE_CACHE_STAGE_DIR:-}" ]]; then
    rm -rf "$SPARKLE_CACHE_STAGE_DIR"
  fi
  if [[ -n "${VERIFY_SCRATCH_DIR:-}" ]]; then
    rm -rf "$VERIFY_SCRATCH_DIR"
  fi
}
trap cleanup_release_fork EXIT

usage() {
  printf '%s\n' "Usage: ./scripts/release-fork.sh --run-number N [options]"
  printf '%s\n' ""
  printf '%s\n' "Builds, signs (Hardened Runtime, inside-out), packages (.dmg), and generates"
  printf '%s\n' "an Ed25519-signed Sparkle appcast.xml for the ClipBook fork."
  printf '%s\n' ""
  printf '%s\n' "Options:"
  printf '%s\n' "  --run-number N               Required positive integer CI/release run number."
  printf '%s\n' "  --upstream-version X.Y.Z     Upstream version baseline (default: FORK_UPSTREAM_VERSION)."
  printf '%s\n' "  --signing-identity ID        macOS codesign identity (default: ClipBook Fork Code Signing)."
  printf '%s\n' "  --keychain PATH              Optional keychain passed to macOS codesign."
  printf '%s\n' "  --p12-file PATH              Headless PKCS#12 bundle path for rcodesign mode."
  printf '%s\n' "  --p12-password-file PATH     File containing the PKCS#12 passphrase (mode 0600)."
  printf '%s\n' "  --rcodesign-bin PATH         Path to SHA-256-verified apple-codesign rcodesign binary."
  printf '%s\n' "  --ed-key-file PATH           File containing 32-byte Base64 Sparkle Ed25519 private seed."
  printf '%s\n' "  --derived-data-path DIR      Xcode DerivedData directory (default: DerivedData/Release)."
  printf '%s\n' "  --repo OWNER/REPO            GitHub repository slug (default: wgordon17/ClipBook)."
  printf '%s\n' "  --previous-build INT         Optional monotonic CFBundleVersion floor."
  printf '%s\n' "  --output-dir DIR             Output root directory (default: Releases/fork)."
  printf '%s\n' "  --arch-list \"arm64 x86_64\"   Space-separated architectures to archive."
  printf '%s\n' "  --sign-and-verify-app PATH   Sign and verify an existing ClipBook.app bundle in place."
  printf '%s\n' "  --smoke-test                 Unprivileged verification mode (ephemeral Ed25519; ad-hoc unless --p12-file is set)."
  printf '%s\n' "  -h, --help                   Show this help."
}

require_option_arg() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    printf 'Error: Option %s requires a value.\n\n' "$1" >&2
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-number)
      require_option_arg "$@"
      RUN_NUMBER="$2"
      shift 2
      ;;
    --upstream-version)
      require_option_arg "$@"
      UPSTREAM_VERSION="$2"
      shift 2
      ;;
    --signing-identity)
      require_option_arg "$@"
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --keychain)
      require_option_arg "$@"
      KEYCHAIN_PATH="$2"
      shift 2
      ;;
    --p12-file)
      require_option_arg "$@"
      P12_FILE="$2"
      shift 2
      ;;
    --p12-password-file)
      require_option_arg "$@"
      P12_PASSWORD_FILE="$2"
      shift 2
      ;;
    --rcodesign-bin)
      require_option_arg "$@"
      SIGNER_BIN="$2"
      shift 2
      ;;
    --ed-key-file)
      require_option_arg "$@"
      ED_KEY_FILE="$2"
      shift 2
      ;;
    --derived-data-path)
      require_option_arg "$@"
      DERIVED_DATA_PATH="$2"
      shift 2
      ;;
    --repo)
      require_option_arg "$@"
      REPO="$2"
      shift 2
      ;;
    --previous-build)
      require_option_arg "$@"
      PREVIOUS_BUILD="$2"
      shift 2
      ;;
    --output-dir)
      require_option_arg "$@"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --arch-list)
      require_option_arg "$@"
      APP_ARCHS="$2"
      APP_ARCHS_EXPLICIT=1
      shift 2
      ;;
    --sign-and-verify-app)
      require_option_arg "$@"
      SIGN_AND_VERIFY_APP="$2"
      shift 2
      ;;
    --smoke-test)
      SMOKE_TEST=1
      shift
      ;;
    -h|--help)
      unset FALLBACK_ED_PRIVKEY
      usage
      exit 0
      ;;
    *)
      unset FALLBACK_ED_PRIVKEY
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

normalize_existing_file() {
  local flag_name="$1"
  local raw_path="$2"
  if [[ ! -f "$raw_path" ]]; then
    printf 'Error: %s file does not exist: %s\n' "$flag_name" "$raw_path" >&2
    exit 1
  fi
  printf '%s/%s\n' "$(cd "$(dirname "$raw_path")" && pwd)" "$(basename "$raw_path")"
}

toml_quote() {
  local LC_ALL=C
  local s="$1"
  if [[ "$s" == *[[:cntrl:]]* ]]; then
    printf 'Error: Path contains ASCII control character and cannot be serialized to TOML.\n' >&2
    exit 1
  fi
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

shell_quote() {
  local val="$1"
  val="${val//\'/\'\\\'\'}"
  printf "'%s'" "$val"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Error: Required tool is missing: %s\n' "$1" >&2
    exit 1
  fi
}

normalize_signing_cli_paths() {
  if [[ -n "$KEYCHAIN_PATH" ]]; then
    KEYCHAIN_PATH="$(normalize_existing_file "--keychain" "$KEYCHAIN_PATH")"
  fi
  if [[ -n "$P12_FILE" ]]; then
    P12_FILE="$(normalize_existing_file "--p12-file" "$P12_FILE")"
  fi
  if [[ -n "$P12_PASSWORD_FILE" ]]; then
    P12_PASSWORD_FILE="$(normalize_existing_file "--p12-password-file" "$P12_PASSWORD_FILE")"
  fi
  if [[ -n "$SIGNER_BIN" ]]; then
    if [[ ! -f "$SIGNER_BIN" || ! -x "$SIGNER_BIN" ]]; then
      printf 'Error: --rcodesign-bin is missing or not executable: %s\n' "$SIGNER_BIN" >&2
      exit 1
    fi
    SIGNER_BIN="$(cd "$(dirname "$SIGNER_BIN")" && pwd)/$(basename "$SIGNER_BIN")"
  fi
  if [[ -n "$P12_FILE" || -n "$P12_PASSWORD_FILE" || -n "$SIGNER_BIN" ]]; then
    if [[ -z "$P12_FILE" || -z "$P12_PASSWORD_FILE" || -z "$SIGNER_BIN" ]]; then
      printf 'Error: --p12-file, --p12-password-file, and --rcodesign-bin must all be provided together.\n' >&2
      exit 1
    fi
  fi
}

parse_and_validate_arch_list() {
  local arch_item
  read -r -a REQUIRED_APP_ARCHS <<< "$APP_ARCHS"
  if [[ "${#REQUIRED_APP_ARCHS[@]}" -eq 0 ]]; then
    printf 'Error: --arch-list must specify at least one architecture.\n' >&2
    exit 1
  fi
  for arch_item in "${REQUIRED_APP_ARCHS[@]}"; do
    if [[ ! "$arch_item" =~ ^[A-Za-z0-9_]+$ ]]; then
      printf 'Error: Invalid architecture token in --arch-list: %s\n' "$arch_item" >&2
      exit 1
    fi
  done
}

extract_and_verify_p12_leaf() {
  local min_valid_seconds="$1"
  local leaf_cert_pem raw_fp leaf_subject
  if [[ ! -x /usr/bin/openssl ]]; then
    printf 'Error: Expected macOS /usr/bin/openssl to be present and executable.\n' >&2
    exit 1
  fi
  if ! leaf_cert_pem="$(/usr/bin/openssl pkcs12 -in "$P12_FILE" -clcerts -nokeys -passin file:"$P12_PASSWORD_FILE" 2>/dev/null)" || [[ -z "$leaf_cert_pem" ]]; then
    printf 'Error: Could not extract leaf certificate PEM from PKCS#12 file (invalid bundle or passphrase).\n' >&2
    exit 1
  fi
  if ! /usr/bin/openssl x509 -noout -checkend "$min_valid_seconds" <<< "$leaf_cert_pem" >/dev/null 2>&1; then
    printf 'Error: PKCS#12 leaf certificate is expired or expires within %s seconds.\n' "$min_valid_seconds" >&2
    exit 1
  fi
  raw_fp="$(/usr/bin/openssl x509 -noout -fingerprint -sha1 <<< "$leaf_cert_pem")"
  LEAF_SHA1="$(printf '%s' "${raw_fp#*=}" | tr -d ':\r\n[:space:]' | tr '[:upper:]' '[:lower:]')"
  if [[ ! "$LEAF_SHA1" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'Error: Could not extract 40-hex leaf SHA-1 fingerprint from PKCS#12 certificate (got: %s).\n' "$LEAF_SHA1" >&2
    exit 1
  fi
  leaf_subject="$(/usr/bin/openssl x509 -noout -subject -nameopt RFC2253 <<< "$leaf_cert_pem" | tr -d '\r\n')"
  if [[ "$leaf_subject" != *CN=* ]]; then
    printf 'Error: PKCS#12 leaf certificate subject is missing CN= (got: %s).\n' "$leaf_subject" >&2
    exit 1
  fi
  EXPECTED_AUTHORITY="${leaf_subject#*CN=}"
  EXPECTED_AUTHORITY="${EXPECTED_AUTHORITY%%,*}"
  if [[ -z "$EXPECTED_AUTHORITY" ]]; then
    printf 'Error: PKCS#12 leaf certificate has an empty Common Name (subject: %s).\n' "$leaf_subject" >&2
    exit 1
  fi
}

run_rcodesign() {
  (
    local bin="$SIGNER_BIN"
    local rc_var
    for rc_var in $(compgen -v RCODESIGN_ || true); do
      unset "$rc_var"
    done
    exec "$bin" "$@"
  )
}

# Normalize paths, validate version/run-number, enforce monotonic build floor, prepare workspace.
if [[ -n "$SIGN_AND_VERIFY_APP" ]]; then
  unset FALLBACK_ED_PRIVKEY

  if [[ -n "$RUN_NUMBER" || -n "$ED_KEY_FILE" ]]; then
    printf 'Error: --sign-and-verify-app cannot be combined with --run-number or --ed-key-file.\n' >&2
    exit 1
  fi
  if [[ ! -d "$SIGN_AND_VERIFY_APP" ]]; then
    printf 'Error: --sign-and-verify-app bundle directory does not exist: %s\n' "$SIGN_AND_VERIFY_APP" >&2
    exit 1
  fi
  APP_PATH="$(cd "$SIGN_AND_VERIFY_APP" && pwd)"
  if [[ ! -f "$APP_PATH/Contents/MacOS/$APP_NAME" ]]; then
    printf 'Error: --sign-and-verify-app bundle is missing Contents/MacOS/%s: %s\n' "$APP_NAME" "$APP_PATH" >&2
    exit 1
  fi

  normalize_signing_cli_paths

  if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    printf 'Error: Release entitlements file not found: %s\n' "$ENTITLEMENTS_PATH" >&2
    exit 1
  fi

  require_tool xcrun
  require_tool ditto

  if [[ "$APP_ARCHS_EXPLICIT" -eq 0 ]]; then
    APP_ARCHS="$(xcrun lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME")"
  fi
  parse_and_validate_arch_list

  VERIFY_SCRATCH_DIR="$(umask 077 && mktemp -d "${TMPDIR:-/var/tmp}/clipbook-verify.XXXXXXXXXX")"
  chmod 700 "$VERIFY_SCRATCH_DIR"
  WORK_DIR="$VERIFY_SCRATCH_DIR"
  STAGING_PATH="$VERIFY_SCRATCH_DIR/dmg-staging"
  mkdir -p "$STAGING_PATH"

  SMOKE_PUBLIC_ED_KEY=""
  EFFECTIVE_SIGNING_IDENTITY="$SIGNING_IDENTITY"
  USES_ADHOC_SIGNING=0
  LEAF_SHA1=""
  REPO_CERT_SHA1=""
  EXPECTED_AUTHORITY="$SIGNING_IDENTITY"

  if [[ -n "$P12_FILE" ]]; then
    extract_and_verify_p12_leaf 3600
  else
    if [[ "$SMOKE_TEST" -eq 1 ]]; then
      EFFECTIVE_SIGNING_IDENTITY="-"
    fi
    if [[ -z "$EFFECTIVE_SIGNING_IDENTITY" ]]; then
      printf 'Error: --signing-identity cannot be empty.\n' >&2
      exit 1
    fi
    if [[ "$EFFECTIVE_SIGNING_IDENTITY" == "-" ]]; then
      USES_ADHOC_SIGNING=1
    elif [[ -f "$ROOT_DIR/scripts/ClipBookForkCodeSigning.crt" && -x /usr/bin/openssl ]]; then
      REPO_RAW_FP="$(/usr/bin/openssl x509 -in "$ROOT_DIR/scripts/ClipBookForkCodeSigning.crt" -noout -fingerprint -sha1 2>/dev/null || true)"
      REPO_CERT_SHA1="$(printf '%s' "${REPO_RAW_FP#*=}" | tr -d ':\r\n[:space:]' | tr '[:upper:]' '[:lower:]')"
    fi
  fi
else
mkdir -p "$OUTPUT_DIR" "$DERIVED_DATA_PATH"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
DERIVED_DATA_PATH="$(cd "$DERIVED_DATA_PATH" && pwd)"

if [[ -n "$ED_KEY_FILE" ]]; then
  ED_KEY_FILE="$(normalize_existing_file "--ed-key-file" "$ED_KEY_FILE")"
fi
normalize_signing_cli_paths

if [[ "$SMOKE_TEST" -eq 1 && -n "$ED_KEY_FILE" ]]; then
  printf 'Error: --smoke-test cannot be combined with --ed-key-file.\n' >&2
  exit 1
fi

if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  printf 'Error: Invalid --repo slug (expected OWNER/REPO): %s\n' "$REPO" >&2
  exit 1
fi

if [[ -z "$UPSTREAM_VERSION" ]]; then
  if [[ ! -f "$ROOT_DIR/FORK_UPSTREAM_VERSION" ]]; then
    printf 'Error: Missing %s and --upstream-version not provided.\n' "$ROOT_DIR/FORK_UPSTREAM_VERSION" >&2
    exit 1
  fi
  UPSTREAM_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/FORK_UPSTREAM_VERSION")"
fi

if [[ ! "$UPSTREAM_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  printf 'Error: Upstream version must match X.Y or X.Y.Z (got: %s).\n' "$UPSTREAM_VERSION" >&2
  exit 1
fi

if [[ -z "$RUN_NUMBER" || ! "$RUN_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Error: --run-number must be a positive integer >= 1 (got: %s).\n' "$RUN_NUMBER" >&2
  exit 1
fi

MARKETING_VERSION="${UPSTREAM_VERSION}+fork.${RUN_NUMBER}"
SAFE_VERSION="${UPSTREAM_VERSION}-fork.${RUN_NUMBER}"
TAG="v${SAFE_VERSION}"
BUILD_NUMBER="$((1000000 + 10#$RUN_NUMBER))"

if [[ -n "$PREVIOUS_BUILD" ]]; then
  if [[ ! "$PREVIOUS_BUILD" =~ ^[0-9]+$ ]]; then
    printf 'Error: --previous-build must be a non-negative integer (got: %s).\n' "$PREVIOUS_BUILD" >&2
    exit 1
  fi
  if (( BUILD_NUMBER <= 10#$PREVIOUS_BUILD )); then
    printf 'Error: Monotonic build check failed: BUILD_NUMBER (%s) must exceed PREVIOUS_BUILD (%s).\n' \
      "$BUILD_NUMBER" "$PREVIOUS_BUILD" >&2
    exit 1
  fi
fi

parse_and_validate_arch_list

if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
  printf 'Error: Release entitlements file not found: %s\n' "$ENTITLEMENTS_PATH" >&2
  exit 1
fi
if [[ ! -x /usr/bin/openssl ]]; then
  printf 'Error: Expected macOS /usr/bin/openssl to be present and executable.\n' >&2
  exit 1
fi

require_tool xcodebuild
require_tool xcrun
require_tool hdiutil
require_tool ditto
require_tool shasum
require_tool swift

WORK_DIR="$OUTPUT_DIR/$SAFE_VERSION-$BUILD_NUMBER"
ARCHIVE_PATH="$WORK_DIR/$APP_NAME.xcarchive"
APP_PATH="$WORK_DIR/$APP_NAME.app"
STAGING_PATH="$WORK_DIR/dmg-staging"
APPCAST_DIR="$OUTPUT_DIR/appcast"
DMG_NAME="$APP_NAME-$SAFE_VERSION.dmg"
DMG_PATH="$WORK_DIR/$DMG_NAME"
APPCAST_PATH="$APPCAST_DIR/appcast.xml"

rm -rf "$WORK_DIR" "$APPCAST_DIR"
rm -f "$OUTPUT_DIR/release-metadata.env"
mkdir -p "$WORK_DIR" "$STAGING_PATH" "$APPCAST_DIR"

# Key, certificate & Sparkle preflight (before any xcodebuild / SwiftPM subprocess runs).
SMOKE_PUBLIC_ED_KEY=""
EFFECTIVE_SIGNING_IDENTITY="$SIGNING_IDENTITY"
USES_ADHOC_SIGNING=0
LEAF_SHA1=""
REPO_CERT_SHA1=""
EXPECTED_AUTHORITY="$SIGNING_IDENTITY"

if [[ "$SMOKE_TEST" -eq 0 ]]; then
  REPO_CERT_PATH="$ROOT_DIR/scripts/ClipBookForkCodeSigning.crt"
  if [[ ! -f "$REPO_CERT_PATH" ]]; then
    printf 'Error: Committed code-signing certificate not found at %s; run bootstrap-fork-signing.sh first.\n' "$REPO_CERT_PATH" >&2
    exit 1
  fi
  if ! /usr/bin/openssl x509 -in "$REPO_CERT_PATH" -noout -checkend 172800 >/dev/null 2>&1; then
    printf 'Error: Committed code-signing certificate (%s) is invalid or expires within 48 hours.\n' "$REPO_CERT_PATH" >&2
    exit 1
  fi
  REPO_RAW_FP="$(/usr/bin/openssl x509 -in "$REPO_CERT_PATH" -noout -fingerprint -sha1)"
  REPO_CERT_SHA1="$(printf '%s' "${REPO_RAW_FP#*=}" | tr -d ':\r\n[:space:]' | tr '[:upper:]' '[:lower:]')"
  if [[ ! "$REPO_CERT_SHA1" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'Error: Could not extract 40-hex SHA-1 fingerprint from %s.\n' "$REPO_CERT_PATH" >&2
    exit 1
  fi
fi

if [[ -n "$P12_FILE" ]]; then
  CERT_MIN_SECONDS=172800
  if [[ "$SMOKE_TEST" -eq 1 ]]; then
    CERT_MIN_SECONDS=3600
  fi
  extract_and_verify_p12_leaf "$CERT_MIN_SECONDS"
  if [[ "$SMOKE_TEST" -eq 0 && "$LEAF_SHA1" != "$REPO_CERT_SHA1" ]]; then
    printf 'Error: PKCS#12 leaf SHA-1 (%s) does not match committed scripts/ClipBookForkCodeSigning.crt (%s).\n' \
      "$LEAF_SHA1" "$REPO_CERT_SHA1" >&2
    exit 1
  fi
fi

if [[ "$SMOKE_TEST" -eq 1 ]]; then
  unset FALLBACK_ED_PRIVKEY
  if [[ -z "$P12_FILE" ]]; then
    EFFECTIVE_SIGNING_IDENTITY="-"
    USES_ADHOC_SIGNING=1
  fi
  SMOKE_KEYPAIR="$(swift -e '
    import CryptoKit
    import Foundation
    let priv = Curve25519.Signing.PrivateKey()
    print(Data(priv.rawRepresentation).base64EncodedString())
    print(Data(priv.publicKey.rawRepresentation).base64EncodedString())
  ')"
  {
    IFS= read -r EFFECTIVE_ED_PRIVKEY
    IFS= read -r SMOKE_PUBLIC_ED_KEY
  } <<< "$SMOKE_KEYPAIR"
  unset SMOKE_KEYPAIR
  if [[ -z "$EFFECTIVE_ED_PRIVKEY" || -z "$SMOKE_PUBLIC_ED_KEY" ]]; then
    printf 'Error: Failed to generate ephemeral smoke-test Ed25519 keypair.\n' >&2
    exit 1
  fi
else
  if [[ -n "$ED_KEY_FILE" ]]; then
    EFFECTIVE_ED_PRIVKEY="$(tr -d '\r\n[:space:]' < "$ED_KEY_FILE")"
  else
    EFFECTIVE_ED_PRIVKEY="$(printf '%s' "$FALLBACK_ED_PRIVKEY" | tr -d '\r\n[:space:]')"
  fi
  unset FALLBACK_ED_PRIVKEY

  if [[ -z "$P12_FILE" && ( -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ) ]]; then
    printf 'Error: Production build requires --p12-file or a non-adhoc --signing-identity.\n' >&2
    exit 1
  fi

  if [[ -z "$EFFECTIVE_ED_PRIVKEY" ]]; then
    printf 'Error: Production build requires Sparkle Ed25519 private key via --ed-key-file.\n' >&2
    exit 1
  fi

  INFO_PUBLIC_ED_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$ROOT_DIR/ClipBook/Info.plist")"
  if [[ "$INFO_PUBLIC_ED_KEY" == "$UPSTREAM_PUBLIC_ED_KEY" ]]; then
    printf 'Error: ClipBook/Info.plist SUPublicEDKey still equals upstream key; run bootstrap-fork-signing.sh first.\n' >&2
    exit 1
  fi

  DERIVED_PUBLIC_ED_KEY="$(printf '%s' "$EFFECTIVE_ED_PRIVKEY" | swift -e '
    import CryptoKit
    import Foundation
    let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let seed = Data(base64Encoded: raw), seed.count == 32 else {
      fputs("Error: Sparkle Ed25519 private key must decode to a 32-byte raw seed.\n", stderr)
      exit(1)
    }
    let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(Data(priv.publicKey.rawRepresentation).base64EncodedString())
  ')"

  if [[ "$DERIVED_PUBLIC_ED_KEY" != "$INFO_PUBLIC_ED_KEY" ]]; then
    printf 'Error: Derived Sparkle Ed25519 public key (%s) does not match ClipBook/Info.plist SUPublicEDKey (%s).\n' \
      "$DERIVED_PUBLIC_ED_KEY" "$INFO_PUBLIC_ED_KEY" >&2
    exit 1
  fi
fi

resolve_sparkle_tool() {
  local tool="$1"

  if [[ -n "${SPARKLE_BIN:-}" ]]; then
    local override="$SPARKLE_BIN/$tool"
    if [[ ! -f "$override" || ! -x "$override" ]]; then
      printf 'Error: SPARKLE_BIN tool is missing or not executable: %s\n' "$override" >&2
      exit 1
    fi
    printf '%s\n' "$override"
    return 0
  fi

  local candidate="$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool"
  if [[ -f "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf 'Error: Could not find Sparkle tool %s at %s\n' "$tool" "$candidate" >&2
  exit 1
}

# Resolve locked SwiftPM packages and build universal Release archive (without -exportArchive).
printf 'Preparing fork release %s (tag %s, build %s).\n' "$MARKETING_VERSION" "$TAG" "$BUILD_NUMBER"
xcodebuild -resolvePackageDependencies \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -onlyUsePackageVersionsFromResolvedFile

GENERATE_APPCAST="$(resolve_sparkle_tool generate_appcast)"
SIGN_UPDATE="$(resolve_sparkle_tool sign_update)"

xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS="$APP_ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_IDENTITY="-"

ARCHIVED_APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [[ ! -d "$ARCHIVED_APP_PATH" ]]; then
  printf 'Error: Archived app bundle not found at %s\n' "$ARCHIVED_APP_PATH" >&2
  exit 1
fi

ditto "$ARCHIVED_APP_PATH" "$APP_PATH"

if [[ "$SMOKE_TEST" -eq 1 ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SMOKE_PUBLIC_ED_KEY" "$APP_PATH/Contents/Info.plist"
fi
if [[ "$REPO" != "wgordon17/ClipBook" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL https://github.com/${REPO}/releases/latest/download/appcast.xml" "$APP_PATH/Contents/Info.plist"
fi
fi

# Inside-out Hardened Runtime signing across all 6 targets (never codesign --deep).
SPARKLE_VERSION_B="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
INSTALLER_XPC="$SPARKLE_VERSION_B/XPCServices/Installer.xpc"
DOWNLOADER_XPC="$SPARKLE_VERSION_B/XPCServices/Downloader.xpc"
AUTOUPDATE_BIN="$SPARKLE_VERSION_B/Autoupdate"
UPDATER_APP="$SPARKLE_VERSION_B/Updater.app"

for required_nested in "$INSTALLER_XPC" "$DOWNLOADER_XPC" "$AUTOUPDATE_BIN" "$UPDATER_APP" "$SPARKLE_VERSION_B"; do
  if [[ ! -e "$required_nested" ]]; then
    printf 'Error: Expected nested Sparkle component missing: %s\n' "$required_nested" >&2
    exit 1
  fi
done

# Strip upstream Developer ID signatures and embedded entitlements (such as Autoupdate's
# com.apple.application-identifier) before re-signing.
for strip_target in \
  "$INSTALLER_XPC" \
  "$DOWNLOADER_XPC" \
  "$AUTOUPDATE_BIN" \
  "$UPDATER_APP" \
  "$SPARKLE_VERSION_B" \
  "$APP_PATH"; do
  /usr/bin/codesign --remove-signature "$strip_target"
done

# Inspect Contents/Resources/*.bundle: strip _CodeSignature inside Mach-O-less SwiftPM
# resource bundles (such as GRDB_GRDB.bundle) so outer CodeResources (^Resources/) seals
# them cleanly, and pass --exclude CLI flags in rcodesign mode.
is_macho_resource_bundle() {
  local bundle_dir="$1"
  local info_plist=""
  if [[ -f "$bundle_dir/Contents/Info.plist" ]]; then
    info_plist="$bundle_dir/Contents/Info.plist"
  elif [[ -f "$bundle_dir/Info.plist" ]]; then
    info_plist="$bundle_dir/Info.plist"
  fi
  local exec_name=""
  if [[ -n "$info_plist" ]]; then
    exec_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info_plist" 2>/dev/null || true)"
  fi
  local exec_path=""
  if [[ -n "$exec_name" ]]; then
    if [[ -f "$bundle_dir/Contents/MacOS/$exec_name" ]]; then
      exec_path="$bundle_dir/Contents/MacOS/$exec_name"
    elif [[ -f "$bundle_dir/$exec_name" ]]; then
      exec_path="$bundle_dir/$exec_name"
    fi
  fi
  [[ -n "$exec_path" ]] && [[ "$(/usr/bin/file -b "$exec_path")" == *"Mach-O"* ]]
}

exclude_args=()
SIGNABLE_RESOURCE_BUNDLES=()
shopt -s nullglob
for res_bundle in "$APP_PATH"/Contents/Resources/*.bundle; do
  [[ -d "$res_bundle" ]] || continue
  res_bundle_name="$(basename "$res_bundle")"
  if is_macho_resource_bundle "$res_bundle"; then
    /usr/bin/codesign --remove-signature "$res_bundle" 2>/dev/null || rm -rf "$res_bundle/Contents/_CodeSignature" "$res_bundle/_CodeSignature"
    SIGNABLE_RESOURCE_BUNDLES+=("$res_bundle")
  else
    rm -rf "$res_bundle/Contents/_CodeSignature" "$res_bundle/_CodeSignature"
    exclude_args+=(--exclude "Contents/Resources/$res_bundle_name")
  fi
done
shopt -u nullglob

if [[ -n "$P12_FILE" ]]; then
  compile_csreq() {
    local target_identifier="$1"
    local output_csreq="$2"
    /usr/bin/csreq -r="identifier \"${target_identifier}\" and certificate leaf = H\"${LEAF_SHA1}\"" -b "$output_csreq"
    if [[ ! -s "$output_csreq" ]]; then
      printf 'Error: /usr/bin/csreq produced empty requirement blob: %s\n' "$output_csreq" >&2
      exit 1
    fi
  }

  compile_csreq "org.sparkle-project.InstallerLauncher" "$WORK_DIR/installer.csreq"
  compile_csreq "org.sparkle-project.DownloaderService" "$WORK_DIR/downloader.csreq"
  compile_csreq "Autoupdate" "$WORK_DIR/autoupdate.csreq"
  compile_csreq "org.sparkle-project.Sparkle.Updater" "$WORK_DIR/updater.csreq"
  compile_csreq "org.sparkle-project.Sparkle" "$WORK_DIR/sparkle.csreq"
  compile_csreq "com.ikryanov.clipbook.v2" "$WORK_DIR/clipbook.csreq"

  q_p12="$(toml_quote "$P12_FILE")"
  q_pass="$(toml_quote "$P12_PASSWORD_FILE")"
  q_clipbook_csreq="$(toml_quote "$WORK_DIR/clipbook.csreq")"
  q_entitlements="$(toml_quote "$ENTITLEMENTS_PATH")"
  q_sparkle_csreq="$(toml_quote "$WORK_DIR/sparkle.csreq")"
  q_autoupdate_csreq="$(toml_quote "$WORK_DIR/autoupdate.csreq")"
  q_updater_csreq="$(toml_quote "$WORK_DIR/updater.csreq")"
  q_installer_csreq="$(toml_quote "$WORK_DIR/installer.csreq")"
  q_downloader_csreq="$(toml_quote "$WORK_DIR/downloader.csreq")"

  SIGNER_TOML="$WORK_DIR/rcodesign.toml"
  {
    printf '[default.sign]\n'
    printf 'signer.p12 = { path = %s, password_path = %s }\n\n' \
      "$q_p12" "$q_pass"

    printf '[default.sign.path."@main"]\n'
    printf 'code_signature_flags = ["runtime"]\n'
    printf 'code_requirements_file = %s\n' "$q_clipbook_csreq"
    printf 'entitlements_xml_file = %s\n\n' "$q_entitlements"

    printf '[default.sign.path."Contents/Frameworks/Sparkle.framework/Versions/B"]\n'
    printf 'code_signature_flags = ["runtime"]\n'
    printf 'code_requirements_file = %s\n\n' "$q_sparkle_csreq"

    printf '[default.sign.path."Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"]\n'
    printf 'binary_identifier = "Autoupdate"\n'
    printf 'code_signature_flags = ["runtime"]\n'
    printf 'code_requirements_file = %s\n\n' "$q_autoupdate_csreq"

    printf '[default.sign.path."Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"]\n'
    printf 'code_signature_flags = ["runtime"]\n'
    printf 'code_requirements_file = %s\n\n' "$q_updater_csreq"

    printf '[default.sign.path."Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"]\n'
    printf 'code_signature_flags = ["runtime"]\n'
    printf 'code_requirements_file = %s\n\n' "$q_installer_csreq"

    printf '[default.sign.path."Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"]\n'
    printf 'code_signature_flags = ["runtime"]\n'
    printf 'code_requirements_file = %s\n' "$q_downloader_csreq"
  } > "$SIGNER_TOML"

  run_rcodesign -C "$SIGNER_TOML" sign --timestamp-url none ${exclude_args[@]+"${exclude_args[@]}"} "$APP_PATH"
else
  CODESIGN_KEYCHAIN_ARGS=()
  if [[ -n "$KEYCHAIN_PATH" && "$EFFECTIVE_SIGNING_IDENTITY" != "-" ]]; then
    CODESIGN_KEYCHAIN_ARGS=(--keychain "$KEYCHAIN_PATH")
  fi

  /usr/bin/codesign --force --sign "$EFFECTIVE_SIGNING_IDENTITY" --options runtime --timestamp=none \
    ${CODESIGN_KEYCHAIN_ARGS[@]+"${CODESIGN_KEYCHAIN_ARGS[@]}"} "$INSTALLER_XPC"
  /usr/bin/codesign --force --sign "$EFFECTIVE_SIGNING_IDENTITY" --options runtime --timestamp=none \
    ${CODESIGN_KEYCHAIN_ARGS[@]+"${CODESIGN_KEYCHAIN_ARGS[@]}"} "$DOWNLOADER_XPC"
  /usr/bin/codesign --force --sign "$EFFECTIVE_SIGNING_IDENTITY" --identifier Autoupdate --options runtime --timestamp=none \
    ${CODESIGN_KEYCHAIN_ARGS[@]+"${CODESIGN_KEYCHAIN_ARGS[@]}"} "$AUTOUPDATE_BIN"
  /usr/bin/codesign --force --sign "$EFFECTIVE_SIGNING_IDENTITY" --options runtime --timestamp=none \
    ${CODESIGN_KEYCHAIN_ARGS[@]+"${CODESIGN_KEYCHAIN_ARGS[@]}"} "$UPDATER_APP"
  /usr/bin/codesign --force --sign "$EFFECTIVE_SIGNING_IDENTITY" --options runtime --timestamp=none \
    ${CODESIGN_KEYCHAIN_ARGS[@]+"${CODESIGN_KEYCHAIN_ARGS[@]}"} "$SPARKLE_VERSION_B"
  for signable_res_bundle in ${SIGNABLE_RESOURCE_BUNDLES[@]+"${SIGNABLE_RESOURCE_BUNDLES[@]}"}; do
    /usr/bin/codesign --force --sign "$EFFECTIVE_SIGNING_IDENTITY" --options runtime --timestamp=none \
      ${CODESIGN_KEYCHAIN_ARGS[@]+"${CODESIGN_KEYCHAIN_ARGS[@]}"} "$signable_res_bundle"
  done
  /usr/bin/codesign --force --sign "$EFFECTIVE_SIGNING_IDENTITY" --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS_PATH" \
    ${CODESIGN_KEYCHAIN_ARGS[@]+"${CODESIGN_KEYCHAIN_ARGS[@]}"} "$APP_PATH"
fi

# Stage and run post-sign binary, signature, DR, entitlement, Mach-O, and Info.plist assertions.
ditto "$APP_PATH" "$STAGING_PATH/ClipBook.app"
ln -s /Applications "$STAGING_PATH/Applications"

STAGED_APP="$STAGING_PATH/ClipBook.app"
STAGED_SPARKLE_B="$STAGED_APP/Contents/Frameworks/Sparkle.framework/Versions/B"

for required_arch in "${REQUIRED_APP_ARCHS[@]}"; do
  xcrun lipo "$STAGED_APP/Contents/MacOS/ClipBook" -verify_arch "$required_arch"
done

if [[ -n "$P12_FILE" ]]; then
  for macho_rel in \
    "Contents/MacOS/ClipBook" \
    "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
    run_rcodesign verify "$STAGED_APP/$macho_rel"
  done
else
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
fi

verify_app_rpaths() {
  local target_app="$1"
  local target_bin="$target_app/Contents/MacOS/ClipBook"
  if [[ ! -f "$target_bin" ]]; then
    printf 'Error: Main executable missing for LC_RPATH check: %s\n' "$target_bin" >&2
    exit 1
  fi

  local otool_out
  otool_out="$(xcrun otool -arch all -l "$target_bin")"

  local in_rpath=0
  local saw_path_in_rpath=0
  local saw_any_load_cmd=0
  local slice_rpath_count=0
  local total_rpath_count=0
  local line rpath_val

  while IFS= read -r line; do
    if [[ "$line" =~ \(architecture\ [A-Za-z0-9_]+\):$ ]]; then
      if [[ "$in_rpath" -eq 1 && "$saw_path_in_rpath" -eq 0 ]]; then
        printf 'Error: Malformed LC_RPATH load command without path entry in %s\n' "$target_bin" >&2
        exit 1
      fi
      if [[ "$saw_any_load_cmd" -eq 1 && "$slice_rpath_count" -le 0 ]]; then
        printf 'Error: Expected at least one LC_RPATH entry in architecture slice of %s\n' "$target_bin" >&2
        exit 1
      fi
      in_rpath=0
      saw_path_in_rpath=0
      saw_any_load_cmd=0
      slice_rpath_count=0
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*Load[[:space:]]+command[[:space:]]+[0-9]+ ]]; then
      if [[ "$in_rpath" -eq 1 && "$saw_path_in_rpath" -eq 0 ]]; then
        printf 'Error: Malformed LC_RPATH load command without path entry in %s\n' "$target_bin" >&2
        exit 1
      fi
      in_rpath=0
      saw_path_in_rpath=0
      saw_any_load_cmd=1
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*cmd[[:space:]]+LC_RPATH[[:space:]]*$ ]]; then
      in_rpath=1
      saw_path_in_rpath=0
      continue
    fi
    if [[ "$in_rpath" -eq 1 && "$line" =~ ^[[:space:]]*path\ (.*)\ \(offset\ [0-9]+\)$ ]]; then
      rpath_val="${BASH_REMATCH[1]}"
      saw_path_in_rpath=1
      slice_rpath_count="$((slice_rpath_count + 1))"
      total_rpath_count="$((total_rpath_count + 1))"
      if [[ "$rpath_val" != "@executable_path/../Frameworks" && "$rpath_val" != "/usr/lib/swift" ]]; then
        printf 'Error: Disallowed LC_RPATH entry "%s" in %s (allowed: @executable_path/../Frameworks, /usr/lib/swift)\n' \
          "$rpath_val" "$target_bin" >&2
        exit 1
      fi
    fi
  done <<< "$otool_out"

  if [[ "$in_rpath" -eq 1 && "$saw_path_in_rpath" -eq 0 ]]; then
    printf 'Error: Malformed trailing LC_RPATH load command without path entry in %s\n' "$target_bin" >&2
    exit 1
  fi
  if [[ "$slice_rpath_count" -le 0 || "$total_rpath_count" -le 0 ]]; then
    printf 'Error: Expected at least one LC_RPATH entry in %s, found %d\n' "$target_bin" "$total_rpath_count" >&2
    exit 1
  fi
}

verify_app_rpaths "$STAGED_APP"

# Offline trustd-free check across Mach-O-less Contents/Resources/*.bundle directories
# (such as GRDB_GRDB.bundle) so --p12-file / rcodesign mode also verifies nested
# _CodeSignature exclusion and outer CodeResources sealing without SecTrustEvaluate.
shopt -s nullglob
for staged_res_bundle in "$STAGED_APP"/Contents/Resources/*.bundle; do
  [[ -d "$staged_res_bundle" ]] || continue
  if is_macho_resource_bundle "$staged_res_bundle"; then
    continue
  fi
  staged_res_bundle_name="$(basename "$staged_res_bundle")"
  if ! [[ ! -e "$staged_res_bundle/Contents/_CodeSignature" && ! -e "$staged_res_bundle/_CodeSignature" ]] \
    || [[ -L "$staged_res_bundle/Contents/_CodeSignature" || -L "$staged_res_bundle/_CodeSignature" ]]; then
    printf 'Error: Mach-O-less resource bundle must not carry nested _CodeSignature: %s\n' "$staged_res_bundle" >&2
    exit 1
  fi
  if [[ -n "$(find "$staged_res_bundle" -type f ! -name '.DS_Store' -print -quit)" ]]; then
    if [[ ! -f "$STAGED_APP/Contents/_CodeSignature/CodeResources" ]] \
      || ! grep -Fq "<key>Resources/${staged_res_bundle_name}/" "$STAGED_APP/Contents/_CodeSignature/CodeResources"; then
      printf 'Error: Outer CodeResources does not seal Mach-O-less resource bundle: %s\n' "$staged_res_bundle" >&2
      exit 1
    fi
  fi
done
shopt -u nullglob

assert_runtime_and_authority() {
  local target_path="$1"
  local dv_out="$2"

  if [[ "$USES_ADHOC_SIGNING" -eq 1 ]]; then
    if ! grep -Eq 'flags=0x10002\(.*runtime.*\)' <<< "$dv_out"; then
      printf 'Error: Expected adhoc+runtime flags (0x10002) on %s, got:\n%s\n' "$target_path" "$dv_out" >&2
      exit 1
    fi
  else
    if ! grep -Eq 'flags=0x10000\(runtime\)' <<< "$dv_out"; then
      printf 'Error: Expected Hardened Runtime flags (0x10000) on %s, got:\n%s\n' "$target_path" "$dv_out" >&2
      exit 1
    fi
    if grep -Fq "Signature=adhoc" <<< "$dv_out"; then
      printf 'Error: Unexpected adhoc signature on production target %s\n' "$target_path" >&2
      exit 1
    fi
    if ! grep -Fq "Authority=${EXPECTED_AUTHORITY}" <<< "$dv_out"; then
      printf 'Error: Missing Authority=%s on %s:\n%s\n' "$EXPECTED_AUTHORITY" "$target_path" "$dv_out" >&2
      exit 1
    fi
  fi
}

verify_signed_target() {
  local target_path="$1"
  local expected_id="$2"
  local is_bundle="$3"
  local is_outer_app="$4"

  local dv_out
  dv_out="$(/usr/bin/codesign -dvvv "$target_path" 2>&1)"

  if ! grep -Fq "Identifier=${expected_id}" <<< "$dv_out"; then
    printf 'Error: Expected Identifier=%s on %s, got:\n%s\n' "$expected_id" "$target_path" "$dv_out" >&2
    exit 1
  fi

  assert_runtime_and_authority "$target_path" "$dv_out"

  if [[ "$is_bundle" -eq 1 ]]; then
    if ! grep -Fq "Sealed Resources version=" <<< "$dv_out" || grep -Fq "Sealed Resources=none" <<< "$dv_out"; then
      printf 'Error: Missing sealed resources on bundle %s:\n%s\n' "$target_path" "$dv_out" >&2
      exit 1
    fi
  fi

  if [[ "$USES_ADHOC_SIGNING" -eq 0 ]]; then
    local dr_out
    dr_out="$(/usr/bin/codesign -dr - "$target_path" 2>&1)"
    if ! grep -Fq "identifier \"${expected_id}\"" <<< "$dr_out" \
      && ! grep -Fq "identifier ${expected_id} " <<< "$dr_out"; then
      printf 'Error: Designated requirement missing identifier "%s" on %s:\n%s\n' "$expected_id" "$target_path" "$dr_out" >&2
      exit 1
    fi
    if ! grep -Fq "certificate leaf" <<< "$dr_out"; then
      printf 'Error: Designated requirement missing certificate leaf constraint on %s:\n%s\n' "$target_path" "$dr_out" >&2
      exit 1
    fi
    if [[ -n "$P12_FILE" ]] && ! grep -Fiq "H\"${LEAF_SHA1}\"" <<< "$dr_out"; then
      printf 'Error: Designated requirement missing leaf hash H"%s" on %s:\n%s\n' "$LEAF_SHA1" "$target_path" "$dr_out" >&2
      exit 1
    elif [[ -z "$P12_FILE" && "$SMOKE_TEST" -eq 0 && "$EFFECTIVE_SIGNING_IDENTITY" == "ClipBook Fork Code Signing" ]] && ! grep -Fiq "H\"${REPO_CERT_SHA1}\"" <<< "$dr_out"; then
      printf 'Error: Designated requirement missing committed certificate leaf hash H"%s" on %s:\n%s\n' "$REPO_CERT_SHA1" "$target_path" "$dr_out" >&2
      exit 1
    fi
  fi

  local ent_xml
  ent_xml="$(/usr/bin/codesign -d --entitlements - --xml "$target_path" 2>/dev/null)"
  if [[ "$is_outer_app" -eq 1 && -z "$ent_xml" ]]; then
    printf 'Error: Outer ClipBook.app is missing embedded entitlements.\n' >&2
    exit 1
  fi
  if [[ -n "$ent_xml" ]]; then
    local ent_tmp="$WORK_DIR/ent-verify.plist"
    printf '%s\n' "$ent_xml" > "$ent_tmp"
    /usr/bin/plutil -lint -s "$ent_tmp"
    local ent_json
    ent_json="$(/usr/bin/plutil -convert json -o - "$ent_tmp")"
    rm -f "$ent_tmp"
    if [[ "$is_outer_app" -eq 1 ]]; then
      if [[ "$ent_json" != '{"com.apple.security.cs.disable-library-validation":true}' ]]; then
        printf 'Error: Outer ClipBook.app entitlements must equal only disable-library-validation=true, got: %s\n' "$ent_json" >&2
        exit 1
      fi
    elif [[ "$ent_json" != '{}' ]]; then
      printf 'Error: Nested Sparkle target %s must carry zero entitlements, got: %s\n' "$target_path" "$ent_json" >&2
      exit 1
    fi
  fi
}

verify_signed_target "$STAGED_APP" "com.ikryanov.clipbook.v2" 1 1
verify_signed_target "$STAGED_SPARKLE_B/XPCServices/Installer.xpc" "org.sparkle-project.InstallerLauncher" 1 0
verify_signed_target "$STAGED_SPARKLE_B/XPCServices/Downloader.xpc" "org.sparkle-project.DownloaderService" 1 0
verify_signed_target "$STAGED_SPARKLE_B/Autoupdate" "Autoupdate" 0 0
verify_signed_target "$STAGED_SPARKLE_B/Updater.app" "org.sparkle-project.Sparkle.Updater" 1 0
verify_signed_target "$STAGED_SPARKLE_B" "org.sparkle-project.Sparkle" 1 0

MACHO_COUNT=0
while IFS= read -r -d '' candidate_file; do
  file_desc="$(/usr/bin/file -b "$candidate_file")"
  if [[ "$file_desc" == *"Mach-O"* ]]; then
    MACHO_COUNT="$((MACHO_COUNT + 1))"
    macho_dv="$(/usr/bin/codesign -dvvv "$candidate_file" 2>&1)"
    if grep -Fq "not signed at all" <<< "$macho_dv"; then
      printf 'Error: Unsigned Mach-O binary found in staged bundle: %s\n' "$candidate_file" >&2
      exit 1
    fi
    assert_runtime_and_authority "$candidate_file" "$macho_dv"
  fi
done < <(find "$STAGED_APP" -type f -print0)

if [[ "$MACHO_COUNT" -lt 6 ]]; then
  printf 'Error: Expected at least 6 Mach-O files in staged app, found %d\n' "$MACHO_COUNT" >&2
  exit 1
fi

assert_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :${key}" "$STAGED_APP/Contents/Info.plist")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Error: Info.plist %s mismatch: expected "%s", got "%s"\n' "$key" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_plist_value "CFBundleIdentifier" "com.ikryanov.clipbook.v2"
if [[ -n "$SIGN_AND_VERIFY_APP" ]]; then
  printf 'Signed and verified app bundle: %s\n' "$APP_PATH"
  exit 0
fi
assert_plist_value "CFBundleShortVersionString" "$MARKETING_VERSION"
assert_plist_value "CFBundleVersion" "$BUILD_NUMBER"
assert_plist_value "SUFeedURL" "https://github.com/${REPO}/releases/latest/download/appcast.xml"
assert_plist_value "SURequireSignedFeed" "true"
assert_plist_value "SUVerifyUpdateBeforeExtraction" "true"
assert_plist_value "SUDefaultsDomain" "com.ikryanov.clipbook.v2.fork.sparkle"

# Create headless UDZO .dmg, generate & verify Ed25519-signed appcast.xml, write release-metadata.env.
hdiutil create \
  -volname "ClipBook" \
  -srcfolder "$STAGING_PATH" \
  -fs HFS+ \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

cp "$DMG_PATH" "$APPCAST_DIR/$DMG_NAME"

if [[ -n "$P12_FILE" ]]; then
  DMG_SHA256="$(shasum -a 256 "$APPCAST_DIR/$DMG_NAME" | cut -d' ' -f1)"
  if [[ ! "$DMG_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'Error: Failed to compute valid SHA-256 for %s\n' "$APPCAST_DIR/$DMG_NAME" >&2
    exit 1
  fi
  SPARKLE_CACHE_STAGE_DIR="$HOME/Library/Caches/Sparkle_generate_appcast/$DMG_SHA256"
  rm -rf "$SPARKLE_CACHE_STAGE_DIR"
  mkdir -p "$SPARKLE_CACHE_STAGE_DIR"
  ditto "$STAGED_APP" "$SPARKLE_CACHE_STAGE_DIR/ClipBook.app"
fi

printf '%s' "$EFFECTIVE_ED_PRIVKEY" | "$GENERATE_APPCAST" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  "$APPCAST_DIR"

printf '%s' "$EFFECTIVE_ED_PRIVKEY" | "$SIGN_UPDATE" \
  --verify \
  --ed-key-file - \
  "$APPCAST_PATH"

unset EFFECTIVE_ED_PRIVKEY

EXPECTED_DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG_NAME}"
if ! grep -Fq "url=\"${EXPECTED_DOWNLOAD_URL}\"" "$APPCAST_PATH"; then
  printf 'Error: appcast.xml missing expected enclosure URL %s\n' "$EXPECTED_DOWNLOAD_URL" >&2
  exit 1
fi
if ! grep -Fq "<sparkle:version>${BUILD_NUMBER}</sparkle:version>" "$APPCAST_PATH"; then
  printf 'Error: appcast.xml missing <sparkle:version>%s</sparkle:version>\n' "$BUILD_NUMBER" >&2
  exit 1
fi
if ! grep -Fq "<sparkle:shortVersionString>${MARKETING_VERSION}</sparkle:shortVersionString>" "$APPCAST_PATH"; then
  printf 'Error: appcast.xml missing <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$MARKETING_VERSION" >&2
  exit 1
fi

METADATA_ENV_PATH="$OUTPUT_DIR/release-metadata.env"
{
  printf 'TAG=%s\n' "$(shell_quote "$TAG")"
  printf 'MARKETING_VERSION=%s\n' "$(shell_quote "$MARKETING_VERSION")"
  printf 'SAFE_VERSION=%s\n' "$(shell_quote "$SAFE_VERSION")"
  printf 'BUILD_NUMBER=%s\n' "$(shell_quote "$BUILD_NUMBER")"
  printf 'DMG_PATH=%s\n' "$(shell_quote "$DMG_PATH")"
  printf 'APPCAST_PATH=%s\n' "$(shell_quote "$APPCAST_PATH")"
} > "$METADATA_ENV_PATH"

printf 'Fork release artifacts verified and ready:\n'
printf '  DMG:      %s\n' "$DMG_PATH"
printf '  Appcast:  %s\n' "$APPCAST_PATH"
printf '  Metadata: %s\n' "$METADATA_ENV_PATH"
