# Offline History & Encrypted Archive Recovery

ClipBook encrypts sensitive rows in `History.sqlite` (`PRAGMA user_version = 5`), managed `.enc` files under `Images/` and `LinkPreviews/`, and passphrase-protected `formatVersion = 2` `.clipbookarchive` exports using `HKDF-SHA256`, `PBKDF2-HMAC-SHA256`, and `AES-256-GCM` with authenticated associated data (AAD).

Because macOS ships LibreSSL (`openssl enc` does not support `AES-256-GCM` with AAD and lacks `openssl kdf`), offline recovery uses Python with [`cryptography`](https://pypi.org/project/cryptography/) via `uv run --with cryptography`.

---

## 1. Obtaining the Master Key (Local Store Recovery)

Certificate-signed Release builds store the 256-bit master key as **64 lowercase ASCII hex characters** in `~/Library/Keychains/login.keychain-db`:

- **Service:** `com.ikryanov.clipbook.v2.encryption`
- **Account:** `master-key-v1`
- **Debug / ad-hoc Release builds (`ClipBook2-Debug/`):** stored in `~/Library/Application Support/ClipBook2-Debug/.devkey` (64 lowercase hex chars).

**GUI Terminal session:**
```bash
KEY_HEX="$(security find-generic-password \
  -s com.ikryanov.clipbook.v2.encryption \
  -a master-key-v1 \
  -w ~/Library/Keychains/login.keychain-db)"
```

**Headless / SSH session** (native `SecItemAdd` items omit `apple-tool:` from the partition list, so `security find-generic-password -w` fails with `errSecInteractionNotAllowed` until `apple-tool:` is added; `-S` replaces the item's entire partition list, so keep `unsigned:` for self-signed Fork builds — and include `teamid:<TEAMID>` if using an Apple Developer ID build — and omit `-k` so `security` prompts on the TTY rather than exposing your keychain password in `ps`):
```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
security set-generic-password-partition-list \
  -s com.ikryanov.clipbook.v2.encryption \
  -a master-key-v1 \
  -S "apple-tool:,apple:,unsigned:" \
  ~/Library/Keychains/login.keychain-db
KEY_HEX="$(security find-generic-password \
  -s com.ikryanov.clipbook.v2.encryption \
  -a master-key-v1 \
  -w ~/Library/Keychains/login.keychain-db)"
```

---

## 2. Wire Format Specification

All `AES-256-GCM` ciphertexts use CryptoKit's `combined` layout: `nonce (12 B) || ciphertext || tag (16 B)`.

### Local Store (`History.sqlite` v5 + `Images/*.enc` / `LinkPreviews/*.enc`)
- **HKDF-SHA256 salt:** `com.ikryanov.clipbook.v2.hkdf.v1`
- **Derived 32-byte keys:**
  - `dbColumnAEADKey`: info = `clipbook.db.column.aes256gcm.v1`
  - `assetFileAEADKey`: info = `clipbook.fs.asset.aes256gcm.v1`
- **Encrypted DB columns** (when `clips.isEncrypted = 1`, sealed with `0x01 || combined`):
  - `clips`: `title`, `textPreview`, `htmlDigest`, `imageDigest`, `assetPath`, `filePathsData`, `linkPreviewData`
  - `clip_contents`: `text`, `qrCodeText`, `rtf`, `html`
  - **Column AAD:** `0x01 || uint8(len(table)) || table_utf8 || uint8(len(column)) || column_utf8 || clip_uuid_16bytes`
- **Encrypted external assets** (`.enc`, sealed with `b"CBENC01\x00" || combined`):
  - **Asset AAD:** `0x01 || uint8(len(role)) || role_utf8 || clip_uuid_16bytes`, where `role` is `"image"`, `"link-preview"`, or `"link-favicon"`.

### Passphrase-Encrypted `.clipbookarchive` (`formatVersion = 2`)
- **Passphrase KDF:** Unicode NFC passphrase → `PBKDF2-HMAC-SHA256(salt=base64_decode(manifest.encryption.saltBase64), iterations=manifest.encryption.iterations, length=32)` → `archiveMasterKey`
- **HKDF-SHA256 salt:** `manifest.encryption.archiveID.lower()` (UTF-8)
- **AEAD key:** info = `clipbook.archive.aes256gcm.v2` (32 bytes)
- **Encrypted entries** (`tags.json.enc`, `history.json.enc`, `assets/**/*.enc`), sealed with `b"CBARC02\x00" || combined`:
  - **Entry AAD:** `0x02 || archive_uuid_16bytes || sha256(raw manifest.json bytes) || uint16_be(len(relativePath)) || relativePath_utf8`, where `relativePath` is the on-disk encrypted path including `.enc` (e.g. `"tags.json.enc"`, `"history.json.enc"`, `"assets/images/<id>.enc"`, `"assets/link-previews/<id>-preview.enc"`).

---

## 3. Decrypt Local `History.sqlite` + Assets

Copies `History.sqlite` (and `-wal` if present) into a temporary directory so the live support directory is never modified, then writes decrypted `history.json` and decrypted `.enc` images into `OUT_DIR`:

```bash
SUPPORT_DIR="$HOME/Library/Application Support/ClipBook2" \
OUT_DIR="$HOME/Desktop/clipbook-recovered" \
KEY_HEX="$KEY_HEX" \
uv run --with cryptography python3 - <<'PY'
import json, os, pathlib, shutil, sqlite3, tempfile, uuid
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

support = pathlib.Path(os.environ["SUPPORT_DIR"])
out = pathlib.Path(os.environ["OUT_DIR"])
os.umask(0o077)
out.mkdir(parents=True, exist_ok=True, mode=0o700)
(out / "assets").mkdir(exist_ok=True, mode=0o700)
master = bytes.fromhex(os.environ["KEY_HEX"].strip())
salt = b"com.ikryanov.clipbook.v2.hkdf.v1"
db_key = AESGCM(HKDF(hashes.SHA256(), 32, salt, b"clipbook.db.column.aes256gcm.v1").derive(master))
asset_key = AESGCM(HKDF(hashes.SHA256(), 32, salt, b"clipbook.fs.asset.aes256gcm.v1").derive(master))

def open_col(val, table, col, uid, enc):
    if val is None: return None
    raw = val if isinstance(val, bytes) else val.encode()
    if not enc: return raw
    assert raw[0] == 1, f"bad version for {uid}.{col}"
    aad = bytes([1, len(table)]) + table.encode() + bytes([len(col)]) + col.encode() + uid.bytes
    return db_key.decrypt(raw[1:13], raw[13:], aad)

def open_asset(path, role, uid):
    raw = pathlib.Path(path).read_bytes()
    if not raw.startswith(b"CBENC01\x00"): return raw
    aad = bytes([1, len(role)]) + role.encode() + uid.bytes
    return asset_key.decrypt(raw[8:20], raw[20:], aad)

with tempfile.TemporaryDirectory() as tmp:
    for name in ("History.sqlite", "History.sqlite-wal"):
        src = support / name
        if src.exists(): shutil.copy2(src, pathlib.Path(tmp) / name)
    conn = sqlite3.connect(pathlib.Path(tmp) / "History.sqlite")
    rows = conn.execute("""
        SELECT c.id, c.kind, c.copiedAt, c.isEncrypted, c.title, c.assetPath, c.filePathsData,
               cc.text, cc.qrCodeText, cc.html
        FROM clips c LEFT JOIN clip_contents cc ON cc.clipId = c.id
        WHERE c.deletedAt IS NULL ORDER BY c.copiedAt DESC
    """).fetchall()

items = []
for cid, kind, copied_at, enc, title, asset_path, fp_data, text, qr, html in rows:
    uid = uuid.UUID(bytes=cid) if isinstance(cid, bytes) else uuid.UUID(cid)
    dec = lambda v, t, col: None if (b := open_col(v, t, col, uid, enc)) is None else b.decode("utf-8", "replace")
    ap = dec(asset_path, "clips", "assetPath")
    out_asset = None
    if ap:
        asset_src = pathlib.Path(ap)
        if not asset_src.is_file():
            asset_src = support / "Images" / asset_src.name
        if asset_src.is_file():
            data = open_asset(asset_src, "image", uid)
            ext = ".png" if data.startswith(b"\x89PNG") else (asset_src.suffix if not asset_src.name.endswith(".enc") else ".bin")
            dest = out / "assets" / f"{uid}{ext}"
            dest.write_bytes(data)
            out_asset = str(dest)
    items.append({
        "id": str(uid), "kind": kind, "copiedAt": copied_at,
        "title": dec(title, "clips", "title"), "text": dec(text, "clip_contents", "text"),
        "qrCodeText": dec(qr, "clip_contents", "qrCodeText"), "html": dec(html, "clip_contents", "html"),
        "filePaths": json.loads(dec(fp_data, "clips", "filePathsData") or "[]"),
        "asset": out_asset,
    })

(out / "history.json").write_text(json.dumps(items, indent=2, ensure_ascii=False))
print(f"Recovered {len(items)} items to {out}")
PY
```

---

## 4. Decrypt a Passphrase-Encrypted `v2` `.clipbookarchive`

```bash
ARCHIVE_DIR="$HOME/Desktop/Backup.clipbookarchive" \
OUT_DIR="$HOME/Desktop/archive-recovered" \
uv run --with cryptography python3 - <<'PY'
import base64, getpass, hashlib, json, os, pathlib, struct, unicodedata, uuid
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

src = pathlib.Path(os.environ["ARCHIVE_DIR"])
out = pathlib.Path(os.environ["OUT_DIR"])
os.umask(0o077)
out.mkdir(parents=True, exist_ok=True, mode=0o700)
manifest_raw = (src / "manifest.json").read_bytes()
manifest = json.loads(manifest_raw)
enc = manifest["encryption"]
archive_id = uuid.UUID(enc["archiveID"])
manifest_sha = hashlib.sha256(manifest_raw).digest()

pw = unicodedata.normalize("NFC", getpass.getpass("Archive passphrase: ")).encode("utf-8")
master = hashlib.pbkdf2_hmac("sha256", pw, base64.b64decode(enc["saltBase64"]), enc["iterations"], 32)
aead = AESGCM(HKDF(hashes.SHA256(), 32, str(archive_id).lower().encode(), b"clipbook.archive.aes256gcm.v2").derive(master))

def open_entry(rel_enc, enc_path):
    raw = enc_path.read_bytes()
    assert raw.startswith(b"CBARC02\x00"), f"bad magic: {enc_path}"
    p = rel_enc.encode("utf-8")
    aad = bytes([2]) + archive_id.bytes + manifest_sha + struct.pack(">H", len(p)) + p
    return aead.decrypt(raw[8:20], raw[20:], aad)

for name in ("tags.json", "history.json"):
    (out / name).write_bytes(open_entry(f"{name}.enc", src / f"{name}.enc"))
assets_dir = src / "assets"
if assets_dir.is_dir():
    for enc_file in assets_dir.rglob("*.enc"):
        rel_enc = enc_file.relative_to(src).as_posix()
        dest = out / rel_enc[:-4]  # strip .enc for plaintext output
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(open_entry(rel_enc, enc_file))
print(f"Decrypted archive to {out}")
PY
```
