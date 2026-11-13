#!/usr/bin/env bash
# Never enable `set -x` in this script: private keys and passphrases are generated in memory.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/DerivedData/Release}"

REPO="wgordon17/ClipBook"
ENV_NAME="release"
BRANCH_POLICY="fork"
CERT_CN="ClipBook Fork Code Signing"
OUTPUT_BACKUP_DIR=""
SKIP_LOCAL_TRUST=0
DRY_RUN=0

WORK_TMP=""
VERIFY_KC=""
LOCAL_TRUST_ADDED=0
REPO_FILES_MUTATED=0
HAD_PREEXISTING_CERT=0

cleanup_bootstrap() {
  local exit_code=$?
  if [[ -n "$VERIFY_KC" ]]; then
    security delete-keychain "$VERIFY_KC" 2>/dev/null || true
  fi
  if [[ "$exit_code" -ne 0 && "$REPO_FILES_MUTATED" -eq 1 && "$LOCAL_TRUST_ADDED" -eq 0 ]]; then
    if [[ -n "$WORK_TMP" && -f "$WORK_TMP/Info.plist.bak" ]]; then
      cp "$WORK_TMP/Info.plist.bak" "$ROOT_DIR/ClipBook/Info.plist" 2>/dev/null || true
      chmod 644 "$ROOT_DIR/ClipBook/Info.plist" 2>/dev/null || true
    fi
    if [[ "$HAD_PREEXISTING_CERT" -eq 1 && -n "$WORK_TMP" && -f "$WORK_TMP/ClipBookForkCodeSigning.crt.bak" ]]; then
      cp "$WORK_TMP/ClipBookForkCodeSigning.crt.bak" "$ROOT_DIR/scripts/ClipBookForkCodeSigning.crt" 2>/dev/null || true
      chmod 644 "$ROOT_DIR/scripts/ClipBookForkCodeSigning.crt" 2>/dev/null || true
    else
      rm -f "$ROOT_DIR/scripts/ClipBookForkCodeSigning.crt" 2>/dev/null || true
    fi
  fi
  if [[ -n "$WORK_TMP" && -d "$WORK_TMP" ]]; then
    rm -rf "$WORK_TMP"
  fi
  if [[ "$exit_code" -ne 0 && "$LOCAL_TRUST_ADDED" -eq 1 ]]; then
    printf '\nBootstrap failed after modifying local certificate trust. Roll back with:\n' >&2
    printf '  security remove-trusted-cert "%s" || true; security delete-certificate -c "%s" "%s" || true; git checkout -- ClipBook/Info.plist && rm -f scripts/ClipBookForkCodeSigning.crt\n' \
      "$ROOT_DIR/scripts/ClipBookForkCodeSigning.crt" \
      "$CERT_CN" \
      "$HOME/Library/Keychains/login.keychain-db" >&2
  fi
}
trap cleanup_bootstrap EXIT

usage() {
  printf '%s\n' "Usage: ./scripts/bootstrap-fork-signing.sh [options]"
  printf '%s\n' ""
  printf '%s\n' "Generates a constrained self-signed codeSigning X.509 PKCS#12 bundle and a"
  printf '%s\n' "Sparkle 2.9.3 Ed25519 keypair, verifies them locally, optionally exports an"
  printf '%s\n' "offline 0700/0600 backup bundle, trusts the public certificate for -p codeSign,"
  printf '%s\n' "and provisions the fork-locked GitHub Environment secrets."
  printf '%s\n' ""
  printf '%s\n' "Options:"
  printf '%s\n' "  --repo OWNER/REPO          GitHub repository slug (default: wgordon17/ClipBook)."
  printf '%s\n' "  --env-name NAME            GitHub Environment name (default: release)."
  printf '%s\n' "  --branch-policy PATTERN    Allowed deployment branch name (default: fork)."
  printf '%s\n' "  --cert-cn NAME             Code-signing certificate Common Name (default: ClipBook Fork Code Signing)."
  printf '%s\n' "  --output-backup-dir DIR    Write 0700/0600 Spotlight & Time Machine excluded backup bundle."
  printf '%s\n' "  --skip-local-trust         Skip login.keychain-db -p codeSign trust installation."
  printf '%s\n' "  --dry-run                  Generate & verify artifacts in temp workspace without modifying repo, Keychain, or GitHub."
  printf '%s\n' "  -h, --help                 Show this help."
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
    --repo)
      require_option_arg "$@"
      REPO="$2"
      shift 2
      ;;
    --env-name)
      require_option_arg "$@"
      ENV_NAME="$2"
      shift 2
      ;;
    --branch-policy)
      require_option_arg "$@"
      BRANCH_POLICY="$2"
      shift 2
      ;;
    --cert-cn)
      require_option_arg "$@"
      CERT_CN="$2"
      shift 2
      ;;
    --output-backup-dir)
      require_option_arg "$@"
      OUTPUT_BACKUP_DIR="$2"
      shift 2
      ;;
    --skip-local-trust)
      SKIP_LOCAL_TRUST=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Error: Required tool is missing: %s\n' "$1" >&2
    exit 1
  fi
}

if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  printf 'Error: Invalid --repo slug (expected OWNER/REPO): %s\n' "$REPO" >&2
  exit 1
fi
if [[ ! "$ENV_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'Error: Invalid --env-name: %s\n' "$ENV_NAME" >&2
  exit 1
fi
if [[ ! "$BRANCH_POLICY" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  printf 'Error: Invalid --branch-policy: %s\n' "$BRANCH_POLICY" >&2
  exit 1
fi
if [[ ! "$CERT_CN" =~ ^[A-Za-z0-9\ ._()-]+$ ]]; then
  printf 'Error: --cert-cn contains unsupported characters: %s\n' "$CERT_CN" >&2
  exit 1
fi

if [[ ! -x /usr/bin/openssl ]]; then
  printf 'Error: Expected macOS /usr/bin/openssl to be present and executable.\n' >&2
  exit 1
fi
require_tool security
require_tool swift
require_tool xcodebuild
if [[ -n "$OUTPUT_BACKUP_DIR" && ! -x /usr/bin/tmutil ]]; then
  printf 'Error: Expected /usr/bin/tmutil for backup directory Time Machine exclusion.\n' >&2
  exit 1
fi

LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

# Live-mode preflight before generating backup files or mutating repo/Keychain/GitHub.
if [[ "$DRY_RUN" -eq 0 ]]; then
  require_tool gh
  if [[ "$SKIP_LOCAL_TRUST" -eq 0 ]]; then
    require_tool uv
  fi

  IS_ADMIN="$(gh api "repos/${REPO}" --jq .permissions.admin)"
  if [[ "$IS_ADMIN" != "true" ]]; then
    printf 'Error: Current gh user does not have admin permissions on %s (got: %s).\n' "$REPO" "$IS_ADMIN" >&2
    exit 1
  fi

  if [[ "$SKIP_LOCAL_TRUST" -eq 0 ]]; then
    EXISTING_CERT_OUT="$(security find-certificate -a -c "$CERT_CN" -Z "$LOGIN_KC" 2>/dev/null || true)"
    if [[ -n "$EXISTING_CERT_OUT" ]]; then
      printf 'Error: Certificate "%s" already exists in %s. Remove it first before re-bootstrapping.\n' \
        "$CERT_CN" "$LOGIN_KC" >&2
      exit 1
    fi
    if security find-identity -p codesigning "$LOGIN_KC" 2>/dev/null | grep -Fq "\"$CERT_CN\""; then
      printf 'Error: Code-signing identity "%s" already exists in %s.\n' "$CERT_CN" "$LOGIN_KC" >&2
      exit 1
    fi
  fi
fi

# Ephemeral workspace & throwaway verification keychain path.
WORK_TMP="$(mktemp -d)"
chmod 700 "$WORK_TMP"
VERIFY_KC="$WORK_TMP/verify.keychain-db"

# Constrained X.509 certificate + cross-macOS PKCS#12 generation via /usr/bin/openssl.
OPENSSL_CNF="$WORK_TMP/openssl.cnf"
{
  printf '[req]\n'
  printf 'distinguished_name = dn\n'
  printf 'x509_extensions = v3_codesign\n'
  printf 'prompt = no\n\n'
  printf '[dn]\n'
  printf 'CN = %s\n\n' "$CERT_CN"
  printf '[v3_codesign]\n'
  printf 'basicConstraints = critical,CA:FALSE\n'
  printf 'keyUsage = critical,digitalSignature\n'
  printf 'extendedKeyUsage = critical,codeSigning\n'
} > "$OPENSSL_CNF"

/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes \
  -keyout "$WORK_TMP/signing.key" \
  -out "$WORK_TMP/signing.crt" \
  -sha256 -days 3650 \
  -config "$OPENSSL_CNF" \
  -extensions v3_codesign 2>/dev/null

P12_PASSWORD="$(/usr/bin/openssl rand -hex 32 | tr -d '\r\n[:space:]')"
if [[ ! "$P12_PASSWORD" =~ ^[0-9a-f]{64}$ ]]; then
  printf 'Error: Failed to generate 32-byte hex PKCS#12 passphrase.\n' >&2
  exit 1
fi

/usr/bin/openssl pkcs12 -export \
  -inkey "$WORK_TMP/signing.key" \
  -in "$WORK_TMP/signing.crt" \
  -name "$CERT_CN" \
  -certpbe PBE-SHA1-3DES \
  -keypbe PBE-SHA1-3DES \
  -macalg sha1 \
  -passout stdin \
  -out "$WORK_TMP/signing.p12" <<< "$P12_PASSWORD"

# Self-verify critical X.509 extensions & macOS security import PKCS#12 compatibility.
CERT_TEXT="$(/usr/bin/openssl x509 -in "$WORK_TMP/signing.crt" -noout -text)"
if ! grep -Eq 'X509v3 Basic Constraints:[[:space:]]*critical' <<< "$CERT_TEXT" || ! grep -Fq 'CA:FALSE' <<< "$CERT_TEXT" || grep -Fq 'CA:TRUE' <<< "$CERT_TEXT"; then
  printf 'Error: Generated X.509 certificate failed critical CA:FALSE constraint check.\n' >&2
  exit 1
fi
if ! grep -Eq 'X509v3 Key Usage:[[:space:]]*critical' <<< "$CERT_TEXT" || ! grep -Fq 'Digital Signature' <<< "$CERT_TEXT"; then
  printf 'Error: Generated X.509 certificate failed critical Digital Signature keyUsage check.\n' >&2
  exit 1
fi
if ! grep -Eq 'X509v3 Extended Key Usage:[[:space:]]*critical' <<< "$CERT_TEXT" || ! grep -Fq 'Code Signing' <<< "$CERT_TEXT"; then
  printf 'Error: Generated X.509 certificate failed critical Code Signing extendedKeyUsage check.\n' >&2
  exit 1
fi
if grep -Fq 'PRIVATE KEY' "$WORK_TMP/signing.crt"; then
  printf 'Error: Public certificate unexpectedly contains private key material.\n' >&2
  exit 1
fi

printf '%s' "$P12_PASSWORD" > "$WORK_TMP/passphrase.verify"
/usr/bin/openssl pkcs12 -in "$WORK_TMP/signing.p12" -clcerts -nokeys -passin file:"$WORK_TMP/passphrase.verify" >/dev/null
rm -f "$WORK_TMP/passphrase.verify"

VERIFY_KC_PASS="$(/usr/bin/openssl rand -hex 32 | tr -d '\r\n[:space:]')"
security create-keychain -p "$VERIFY_KC_PASS" "$VERIFY_KC"
security unlock-keychain -p "$VERIFY_KC_PASS" "$VERIFY_KC"
security import "$WORK_TMP/signing.p12" \
  -k "$VERIFY_KC" \
  -P "$P12_PASSWORD" \
  -f pkcs12 \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null
security delete-keychain "$VERIFY_KC"
unset VERIFY_KC_PASS

# Generate Sparkle 2.9.3 32-byte Ed25519 seed + public key and verify with sign_update.
ED_KEYPAIR_OUT="$(swift -e '
  import CryptoKit
  import Foundation
  let priv = Curve25519.Signing.PrivateKey()
  let privData = Data(priv.rawRepresentation)
  let pubData = Data(priv.publicKey.rawRepresentation)
  guard privData.count == 32, pubData.count == 32 else {
    exit(1)
  }
  print(privData.base64EncodedString())
  print(pubData.base64EncodedString())
')"

SPARKLE_PRIV_B64=""
SPARKLE_PUB_B64=""
{
  IFS= read -r SPARKLE_PRIV_B64
  IFS= read -r SPARKLE_PUB_B64
} <<< "$ED_KEYPAIR_OUT"
unset ED_KEYPAIR_OUT

if [[ "${#SPARKLE_PRIV_B64}" -ne 44 || "${#SPARKLE_PUB_B64}" -ne 44 ]]; then
  printf 'Error: Expected 44-character Base64 Ed25519 keys.\n' >&2
  exit 1
fi

find_sparkle_sign_update() {
  local candidates=()
  if [[ -n "${SPARKLE_BIN:-}" ]]; then
    candidates+=("$SPARKLE_BIN/sign_update")
  fi
  candidates+=("$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update")
  shopt -s nullglob
  candidates+=("$DERIVED_DATA_PATH"/SourcePackages/artifacts/*/Sparkle/bin/sign_update)
  candidates+=("$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/*/Sparkle/bin/sign_update)
  shopt -u nullglob

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

SIGN_UPDATE="$(find_sparkle_sign_update || true)"
if [[ -z "$SIGN_UPDATE" ]]; then
  mkdir -p "$DERIVED_DATA_PATH"
  xcodebuild -resolvePackageDependencies \
    -project "$ROOT_DIR/ClipBook.xcodeproj" \
    -scheme "ClipBook" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -onlyUsePackageVersionsFromResolvedFile >/dev/null
  SIGN_UPDATE="$(find_sparkle_sign_update)"
fi

VERIFY_APPCAST_XML="$WORK_TMP/verify-appcast.xml"
printf '%s\n' '<?xml version="1.0" encoding="utf-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Verify</title></channel></rss>' > "$VERIFY_APPCAST_XML"
printf '%s' "$SPARKLE_PRIV_B64" | "$SIGN_UPDATE" --ed-key-file - "$VERIFY_APPCAST_XML" >/dev/null
printf '%s' "$SPARKLE_PRIV_B64" | "$SIGN_UPDATE" --verify --ed-key-file - "$VERIFY_APPCAST_XML" >/dev/null

write_backup_bundle() {
  if [[ -z "$OUTPUT_BACKUP_DIR" ]]; then
    return 0
  fi
  mkdir -p "$OUTPUT_BACKUP_DIR"
  chmod 700 "$OUTPUT_BACKUP_DIR"
  OUTPUT_BACKUP_DIR="$(cd "$OUTPUT_BACKUP_DIR" && pwd)"

  : > "$OUTPUT_BACKUP_DIR/.metadata_never_index"
  chmod 600 "$OUTPUT_BACKUP_DIR/.metadata_never_index"
  /usr/bin/tmutil addexclusion "$OUTPUT_BACKUP_DIR" >/dev/null

  cp "$WORK_TMP/signing.crt" "$OUTPUT_BACKUP_DIR/signing.crt"
  cp "$WORK_TMP/signing.p12" "$OUTPUT_BACKUP_DIR/signing.p12"
  printf '%s' "$P12_PASSWORD" > "$OUTPUT_BACKUP_DIR/signing.p12.passphrase"
  printf '%s' "$SPARKLE_PRIV_B64" > "$OUTPUT_BACKUP_DIR/sparkle_ed25519.key"
  printf '%s\n' "$SPARKLE_PUB_B64" > "$OUTPUT_BACKUP_DIR/sparkle_ed25519.pub"
  chmod 600 \
    "$OUTPUT_BACKUP_DIR/signing.crt" \
    "$OUTPUT_BACKUP_DIR/signing.p12" \
    "$OUTPUT_BACKUP_DIR/signing.p12.passphrase" \
    "$OUTPUT_BACKUP_DIR/sparkle_ed25519.key" \
    "$OUTPUT_BACKUP_DIR/sparkle_ed25519.pub"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  write_backup_bundle
  unset P12_PASSWORD SPARKLE_PRIV_B64
  printf 'Dry-run verification succeeded:\n'
  printf '  - Constrained X.509 RSA-3072 certificate (critical CA:FALSE, digitalSignature, codeSigning)\n'
  printf '  - Cross-macOS PKCS#12 export & throwaway keychain security import verified\n'
  printf '  - Sparkle 2.9.3 Ed25519 32-byte keypair generated & sign_update --verify succeeded\n'
  if [[ -n "$OUTPUT_BACKUP_DIR" ]]; then
    printf '  - Backup bundle written (0700/0600, Spotlight + Time Machine excluded): %s\n' "$OUTPUT_BACKUP_DIR"
  fi
  printf '  - Repository files, login.keychain-db, and GitHub were left untouched.\n'
  exit 0
fi

# Live provisioning — lock fork-only GitHub Environment first, back up & update repo files,
# install local -p codeSign trust, and upload Environment secrets.
PUBLIC_CERT_DEST="$ROOT_DIR/scripts/ClipBookForkCodeSigning.crt"
INFO_PLIST_DEST="$ROOT_DIR/ClipBook/Info.plist"

gh api --method PUT "repos/${REPO}/environments/${ENV_NAME}" --input - >/dev/null \
  <<< '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'

MATCHING_POLICIES="$(gh api "repos/${REPO}/environments/${ENV_NAME}/deployment-branch-policies" \
  --jq "[.branch_policies[] | select(.name == \"${BRANCH_POLICY}\" and .type == \"branch\")] | length")"
if [[ "$MATCHING_POLICIES" == "0" ]]; then
  gh api --method POST "repos/${REPO}/environments/${ENV_NAME}/deployment-branch-policies" \
    -f name="$BRANCH_POLICY" -f type="branch" >/dev/null
fi

STALE_POLICY_IDS="$(gh api "repos/${REPO}/environments/${ENV_NAME}/deployment-branch-policies" \
  --jq ".branch_policies[] | select(.name != \"${BRANCH_POLICY}\" or .type != \"branch\") | .id")"
if [[ -n "$STALE_POLICY_IDS" ]]; then
  while IFS= read -r policy_id; do
    [[ -n "$policy_id" ]] || continue
    gh api --method DELETE "repos/${REPO}/environments/${ENV_NAME}/deployment-branch-policies/${policy_id}" >/dev/null
  done <<< "$STALE_POLICY_IDS"
fi

POLICY_VERIFIED="$(gh api "repos/${REPO}/environments/${ENV_NAME}/deployment-branch-policies" \
  --jq "(.total_count == 1) and ((.branch_policies | length) == 1) and (.branch_policies[0].name == \"${BRANCH_POLICY}\") and (.branch_policies[0].type == \"branch\")")"
if [[ "$POLICY_VERIFIED" != "true" ]]; then
  printf 'Error: GitHub Environment "%s" deployment-branch-policies did not lock exclusively to branch "%s". Aborting before mutating repo or uploading secrets.\n' \
    "$ENV_NAME" "$BRANCH_POLICY" >&2
  exit 1
fi

cp "$INFO_PLIST_DEST" "$WORK_TMP/Info.plist.bak"
if [[ -f "$PUBLIC_CERT_DEST" ]]; then
  HAD_PREEXISTING_CERT=1
  cp "$PUBLIC_CERT_DEST" "$WORK_TMP/ClipBookForkCodeSigning.crt.bak"
fi
REPO_FILES_MUTATED=1

cp "$WORK_TMP/signing.crt" "$PUBLIC_CERT_DEST"
chmod 644 "$PUBLIC_CERT_DEST"

/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUB_B64" "$INFO_PLIST_DEST"
chmod 644 "$INFO_PLIST_DEST"

if [[ "$SKIP_LOCAL_TRUST" -eq 0 ]]; then
  LOCAL_TRUST_ADDED=1
  security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KC" "$PUBLIC_CERT_DEST"

  security dump-trust-settings | EXPECTED_CERT_CN="$CERT_CN" uv run --no-project python3 -c '
import os, re, sys

expected_cn = os.environ["EXPECTED_CERT_CN"]
dump = sys.stdin.read()
parts = re.split(r"(?m)^Cert \d+:\s*", dump)
matching = []
for part in parts[1:]:
    lines = part.splitlines()
    if not lines:
        continue
    cn = lines[0].strip()
    body = "\n".join(lines[1:])
    if cn == expected_cn:
        matching.append(body)

if len(matching) != 1:
    sys.stderr.write(f"Error: Expected exactly 1 trust stanza for {expected_cn!r}, found {len(matching)}.\n")
    sys.exit(1)

stanza = matching[0]
if not re.search(r"Number of trust settings\s*:\s*1\b", stanza):
    sys.stderr.write("Error: Certificate trust stanza must contain exactly 1 trust setting.\n")
    sys.exit(1)
if not re.search(r"Policy OID\s*:\s*Code Signing\b", stanza):
    sys.stderr.write("Error: Certificate trust setting is not scoped to Code Signing policy.\n")
    sys.exit(1)
'
fi

base64 < "$WORK_TMP/signing.p12" | tr -d '\r\n' | gh secret set MACOS_CERT_P12_BASE64 --env "$ENV_NAME" --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERT_PASSWORD --env "$ENV_NAME" --repo "$REPO"
printf '%s' "$SPARKLE_PRIV_B64" | gh secret set SPARKLE_ED25519_PRIVATE_KEY --env "$ENV_NAME" --repo "$REPO"

write_backup_bundle
unset P12_PASSWORD SPARKLE_PRIV_B64

printf 'Fork signing bootstrap completed:\n'
printf '  - Public certificate: %s\n' "$PUBLIC_CERT_DEST"
printf '  - Updated SUPublicEDKey in: %s\n' "$INFO_PLIST_DEST"
printf '  - Provisioned GitHub Environment "%s" on %s (branch policy: %s)\n' "$ENV_NAME" "$REPO" "$BRANCH_POLICY"
if [[ -n "$OUTPUT_BACKUP_DIR" ]]; then
  printf '\nIMPORTANT: Import %s into your encrypted offline vault (e.g. 1Password),\n' "$OUTPUT_BACKUP_DIR"
  printf 'then delete the plaintext backup directory immediately (rm -rf "%s").\n' "$OUTPUT_BACKUP_DIR"
fi
printf '\nNOTE: When switching /Applications/ClipBook.app between Upstream and Fork builds,\n'
printf 'reset macOS Accessibility TCC once with:\n'
printf '  tccutil reset Accessibility com.ikryanov.clipbook.v2\n'
