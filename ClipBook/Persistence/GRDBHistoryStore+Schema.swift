import Foundation
import GRDB

nonisolated extension GRDBHistoryStore {
    nonisolated enum AEADTable {
        static let clips = "clips"
        static let clipContents = "clip_contents"
    }

    nonisolated enum ClipAEADColumn: String, Sendable {
        case title
        case textPreview
        case htmlDigest
        case imageDigest
        case assetPath
        case filePathsData
        case linkPreviewData
    }

    nonisolated enum ClipContentAEADColumn: String, Sendable {
        case text
        case qrCodeText
        case rtf
        case html
    }

    nonisolated enum SealedColumn: Sendable {
        case clip(ClipAEADColumn)
        case clipContent(ClipContentAEADColumn)

        var aadTable: String {
            switch self {
            case .clip:
                return AEADTable.clips
            case .clipContent:
                return AEADTable.clipContents
            }
        }

        var aadColumn: String {
            switch self {
            case .clip(let column):
                return column.rawValue
            case .clipContent(let column):
                return column.rawValue
            }
        }
    }

    // MARK: - Normalized v5 DDL

    static func createV5Schema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS tags (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                color TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS clips (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                copiedAt REAL NOT NULL,
                firstCopiedAt REAL NOT NULL,
                deletedAt REAL,
                expiresAt REAL,
                copySequenceID REAL,
                copySequenceOrder INTEGER,
                byteSize INTEGER NOT NULL,
                copyCount INTEGER NOT NULL,
                isFavorite INTEGER NOT NULL,
                favoriteOrder INTEGER,
                sourceAppName TEXT,
                sourceBundleIdentifier TEXT,
                sensitivity TEXT,
                isEncrypted INTEGER NOT NULL DEFAULT 0,
                title BLOB,
                textPreview BLOB,
                characterCount INTEGER NOT NULL DEFAULT 0,
                containsPreviewSecret INTEGER NOT NULL DEFAULT 0,
                containsRestSecret INTEGER NOT NULL DEFAULT 0,
                hasRecognizedText INTEGER NOT NULL DEFAULT 0,
                hasQRCodeText INTEGER NOT NULL DEFAULT 0,
                isSVGText INTEGER NOT NULL DEFAULT 0,
                hasFormatting INTEGER NOT NULL DEFAULT 0,
                htmlDigest BLOB,
                imageDigest BLOB,
                imageWidth INTEGER,
                imageHeight INTEGER,
                assetPath BLOB,
                filePathsData BLOB NOT NULL,
                linkPreviewData BLOB,
                contentKey BLOB NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_clips_active_copiedAt
                ON clips(copiedAt DESC) WHERE deletedAt IS NULL;
            CREATE INDEX IF NOT EXISTS idx_clips_trashed_deletedAt
                ON clips(deletedAt DESC) WHERE deletedAt IS NOT NULL;
            CREATE INDEX IF NOT EXISTS idx_clips_active_kind_copiedAt
                ON clips(kind, copiedAt DESC) WHERE deletedAt IS NULL;
            CREATE INDEX IF NOT EXISTS idx_clips_kind_contentKey
                ON clips(kind, contentKey);
            CREATE INDEX IF NOT EXISTS idx_clips_expiresAt
                ON clips(expiresAt) WHERE expiresAt IS NOT NULL;
            CREATE INDEX IF NOT EXISTS idx_clips_stored_files
                ON clips(id) WHERE assetPath IS NOT NULL OR linkPreviewData IS NOT NULL;

            CREATE TABLE IF NOT EXISTS clip_contents (
                clipId TEXT PRIMARY KEY NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                text BLOB,
                qrCodeText BLOB,
                rtf BLOB,
                html BLOB
            );

            CREATE TABLE IF NOT EXISTS clip_tags (
                clipId TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                tagId INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                sortOrder INTEGER,
                PRIMARY KEY (clipId, tagId)
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS idx_clip_tags_tagId ON clip_tags(tagId);

            CREATE TABLE IF NOT EXISTS store_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value BLOB NOT NULL
            );
            """)
    }
}
