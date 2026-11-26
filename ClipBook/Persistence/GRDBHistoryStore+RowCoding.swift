import Foundation
import GRDB

nonisolated extension GRDBHistoryStore {
    nonisolated struct TagAttachment {
        var tagIDs: [Int] = []
        var tagNames: [String] = []
        var tagOrders: [Int: Int] = [:]

        mutating func append(row: Row) {
            let tagID: Int = row["tagId"]
            let tagName: String = row["name"]
            let sortOrder: Int? = row["sortOrder"]
            tagIDs.append(tagID)
            tagNames.append(tagName)
            if let sortOrder {
                tagOrders[tagID] = sortOrder
            }
        }
    }

    // MARK: - Column AEAD & Row Decoding Helpers

    static func encodeStringColumn(
        _ value: String?,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data? {
        guard let value else {
            return nil
        }
        let utf8 = Data(value.utf8)
        if isEncrypted {
            return try HistoryCrypto.sealColumn(
                utf8,
                table: column.aadTable,
                column: column.aadColumn,
                clipID: clipID,
                keys: keys
            )
        }
        return utf8
    }

    static func encodeOptionalDataColumn(
        _ value: Data?,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data? {
        guard let value else {
            return nil
        }
        if isEncrypted {
            return try HistoryCrypto.sealColumn(
                value,
                table: column.aadTable,
                column: column.aadColumn,
                clipID: clipID,
                keys: keys
            )
        }
        return value
    }

    static func encodeRequiredDataColumn(
        _ value: Data,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data {
        if isEncrypted {
            return try HistoryCrypto.sealColumn(
                value,
                table: column.aadTable,
                column: column.aadColumn,
                clipID: clipID,
                keys: keys
            )
        }
        return value
    }

    private static func decodeDataValue(
        _ dbValue: DatabaseValue,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data? {
        switch dbValue.storage {
        case .null:
            return nil
        case .blob(let data):
            if isEncrypted {
                return try HistoryCrypto.openColumn(
                    data,
                    table: column.aadTable,
                    column: column.aadColumn,
                    clipID: clipID,
                    keys: keys
                )
            }
            return data
        case .string(let string):
            if isEncrypted {
                throw HistoryStoreError.authenticationFailed
            }
            return Data(string.utf8)
        case .int64, .double:
            throw HistoryStoreError.authenticationFailed
        }
    }

    static func decodeUTF8String(_ data: Data) throws -> String {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw HistoryStoreError.authenticationFailed
        }
        return decoded
    }

    private static func decodeStringValue(
        _ dbValue: DatabaseValue,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> String? {
        switch dbValue.storage {
        case .null:
            return nil
        case .string(let string):
            if isEncrypted {
                throw HistoryStoreError.authenticationFailed
            }
            return string
        case .blob(let data):
            let plaintext: Data
            if isEncrypted {
                plaintext = try HistoryCrypto.openColumn(
                    data,
                    table: column.aadTable,
                    column: column.aadColumn,
                    clipID: clipID,
                    keys: keys
                )
            } else {
                plaintext = data
            }
            return try decodeUTF8String(plaintext)
        case .int64, .double:
            throw HistoryStoreError.authenticationFailed
        }
    }

    private static func decodeUnencryptedString(from row: Row, atIndex index: Int) throws -> String? {
        try row.withUnsafeData(atIndex: index) { data in
            guard let data else {
                return nil
            }
            return try decodeUTF8String(data)
        }
    }

    private static func decodeUnencryptedFilePaths(
        from row: Row,
        atIndex index: Int,
        decoder: JSONDecoder
    ) throws -> [String] {
        try row.withUnsafeData(atIndex: index) { data in
            guard let jsonData = data else {
                throw HistoryStoreError.authenticationFailed
            }
            if jsonData.count == 2,
               jsonData[jsonData.startIndex] == 0x5B,
               jsonData[jsonData.index(after: jsonData.startIndex)] == 0x5D {
                return []
            }
            do {
                return try decoder.decode([String].self, from: jsonData)
            } catch {
                throw HistoryStoreError.authenticationFailed
            }
        }
    }

    private static func decodeUnencryptedLinkPreview(
        from row: Row,
        atIndex index: Int,
        decoder: JSONDecoder
    ) throws -> LinkPreviewDetails? {
        try row.withUnsafeData(atIndex: index) { data in
            guard let jsonData = data else {
                return nil
            }
            do {
                return try decoder.decode(LinkPreviewDetails.self, from: jsonData)
            } catch {
                throw HistoryStoreError.authenticationFailed
            }
        }
    }

    static func decodeDataColumn(
        from row: Row,
        rowColumn: String? = nil,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data? {
        let dbValue: DatabaseValue = row[rowColumn ?? column.aadColumn]
        return try decodeDataValue(
            dbValue,
            column: column,
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
    }

    static func decodeRequiredDataColumn(
        from row: Row,
        rowColumn: String? = nil,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> Data {
        guard let data = try decodeDataColumn(
            from: row,
            rowColumn: rowColumn,
            column: column,
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) else {
            throw HistoryStoreError.authenticationFailed
        }
        return data
    }

    static func decodeStringColumn(
        from row: Row,
        rowColumn: String? = nil,
        column: SealedColumn,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> String? {
        let dbValue: DatabaseValue = row[rowColumn ?? column.aadColumn]
        return try decodeStringValue(
            dbValue,
            column: column,
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        )
    }

    private static func hasEncryptedAssetExtension(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "enc"
    }

    static func decodeProtectedAssetPath(
        from row: Row,
        rowColumn: String = ClipAEADColumn.assetPath.rawValue,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys
    ) throws -> String? {
        guard let path = try decodeStringColumn(
            from: row,
            rowColumn: rowColumn,
            column: .clip(.assetPath),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) else {
            return nil
        }
        if isEncrypted && !hasEncryptedAssetExtension(path) {
            throw HistoryStoreError.authenticationFailed
        }
        return path
    }

    static func decodeProtectedLinkPreview(
        from row: Row,
        rowColumn: String = ClipAEADColumn.linkPreviewData.rawValue,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> LinkPreviewDetails? {
        try decodeProtectedLinkPreviewValue(
            row[rowColumn],
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys,
            decoder: decoder
        )
    }

    static func decodeProtectedFilePaths(
        from row: Row,
        rowColumn: String = ClipAEADColumn.filePathsData.rawValue,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> [String] {
        try decodeProtectedFilePathsValue(
            row[rowColumn],
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys,
            decoder: decoder
        )
    }

    nonisolated struct UnsealedClipHeaderMetadata {
        let id: UUID
        let kind: ClipboardKind
        let copiedAt: Date
        let firstCopiedAt: Date
        let deletedAt: Date?
        let expiresAt: Date?
        let copySequenceID: Date?
        let copySequenceOrder: Int?
        let byteSize: Int
        let copyCount: Int
        let isFavorite: Bool
        let favoriteOrder: Int?
        let sourceAppName: String?
        let sourceBundleIdentifier: String?
        let sensitivity: ItemSensitivity?
        let isEncrypted: Bool
        let storedContentKey: Data?
        let characterCount: Int
        let containsPreviewSecret: Bool
        let containsRestSecret: Bool
        let hasRecognizedText: Bool
        let hasQRCodeText: Bool
        let isSVGText: Bool
        let hasFormatting: Bool
        let imageWidth: Int?
        let imageHeight: Int?

        init?(row: Row) {
            guard let idString: String = row["id"],
                  let clipID = UUID(uuidString: idString) else {
                return nil
            }
            let kindRaw: String = row["kind"] ?? ClipboardKind.text.rawValue
            let copiedAtTimestamp = (row["copiedAt"] as Double?) ?? 0

            self.id = clipID
            self.kind = ClipboardKind(rawValue: kindRaw) ?? .text
            self.copiedAt = Date(timeIntervalSince1970: copiedAtTimestamp)
            self.firstCopiedAt = Date(timeIntervalSince1970: (row["firstCopiedAt"] as Double?) ?? copiedAtTimestamp)
            self.deletedAt = (row["deletedAt"] as Double?).map(Date.init(timeIntervalSince1970:))
            self.expiresAt = (row["expiresAt"] as Double?).map(Date.init(timeIntervalSince1970:))
            self.copySequenceID = (row["copySequenceID"] as Double?).map(Date.init(timeIntervalSince1970:))
            self.copySequenceOrder = row["copySequenceOrder"]
            self.byteSize = row["byteSize"] ?? 0
            self.copyCount = row["copyCount"] ?? 0
            self.isFavorite = ((row["isFavorite"] as Int?) ?? 0) != 0
            self.favoriteOrder = row["favoriteOrder"]
            self.sourceAppName = row["sourceAppName"]
            self.sourceBundleIdentifier = row["sourceBundleIdentifier"]
            self.sensitivity = (row["sensitivity"] as String?).flatMap(ItemSensitivity.init(rawValue:))
            self.isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0
            self.storedContentKey = row["contentKey"]
            self.characterCount = (row["characterCount"] as Int?) ?? 0
            self.containsPreviewSecret = ((row["containsPreviewSecret"] as Int?) ?? 0) != 0
            self.containsRestSecret = ((row["containsRestSecret"] as Int?) ?? 0) != 0
            self.hasRecognizedText = ((row["hasRecognizedText"] as Int?) ?? 0) != 0
            self.hasQRCodeText = ((row["hasQRCodeText"] as Int?) ?? 0) != 0
            self.isSVGText = ((row["isSVGText"] as Int?) ?? 0) != 0
            self.hasFormatting = ((row["hasFormatting"] as Int?) ?? 0) != 0
            self.imageWidth = row["imageWidth"]
            self.imageHeight = row["imageHeight"]
        }
    }

    private nonisolated struct SealedClipHeaderFields {
        let title: String?
        let textPreview: String?
        let htmlDigest: String?
        let imageDigest: String?
        let assetPath: String?
        let filePaths: [String]
        let linkPreviewDetails: LinkPreviewDetails?
    }

    private static func decodeSealedClipHeaderFields(
        from row: Row,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> SealedClipHeaderFields {
        SealedClipHeaderFields(
            title: try decodeStringColumn(
                from: row,
                column: .clip(.title),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            ),
            textPreview: try decodeStringColumn(
                from: row,
                column: .clip(.textPreview),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            ),
            htmlDigest: try decodeStringColumn(
                from: row,
                column: .clip(.htmlDigest),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            ),
            imageDigest: try decodeStringColumn(
                from: row,
                column: .clip(.imageDigest),
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            ),
            assetPath: try decodeProtectedAssetPath(
                from: row,
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys
            ),
            filePaths: try decodeProtectedFilePaths(
                from: row,
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys,
                decoder: decoder
            ),
            linkPreviewDetails: try decodeProtectedLinkPreview(
                from: row,
                clipID: clipID,
                isEncrypted: isEncrypted,
                keys: keys,
                decoder: decoder
            )
        )
    }

    static func authenticateEncryptedClipHeaderColumns(
        in row: Row,
        clipID: UUID,
        keys: ClipBookDerivedKeys
    ) throws {
        _ = try decodeSealedClipHeaderFields(
            from: row,
            clipID: clipID,
            isEncrypted: true,
            keys: keys,
            decoder: makeJSONDecoder()
        )
    }

    private static func makeStoredHeaderItem(
        metadata: UnsealedClipHeaderMetadata,
        sealed: SealedClipHeaderFields,
        attachment: TagAttachment
    ) -> ClipboardItem {
        ClipboardItem.fromStoredHeader(
            id: metadata.id,
            kind: metadata.kind,
            title: sealed.title,
            textPreview: sealed.textPreview,
            characterCount: metadata.characterCount,
            containsPreviewSecret: metadata.containsPreviewSecret,
            containsRestSecret: metadata.containsRestSecret,
            hasRecognizedText: metadata.hasRecognizedText,
            hasQRCodeText: metadata.hasQRCodeText,
            isSVGText: metadata.isSVGText,
            hasFormatting: metadata.hasFormatting,
            htmlDigest: sealed.htmlDigest,
            imageDigest: sealed.imageDigest,
            imageWidth: metadata.imageWidth,
            imageHeight: metadata.imageHeight,
            assetPath: sealed.assetPath,
            filePaths: sealed.filePaths,
            sourceAppName: metadata.sourceAppName,
            sourceBundleIdentifier: metadata.sourceBundleIdentifier,
            copiedAt: metadata.copiedAt,
            firstCopiedAt: metadata.firstCopiedAt,
            byteSize: metadata.byteSize,
            isFavorite: metadata.isFavorite,
            tags: attachment.tagIDs,
            tagOrders: attachment.tagOrders,
            copyCount: metadata.copyCount,
            linkPreviewDetails: sealed.linkPreviewDetails,
            copySequenceID: metadata.copySequenceID,
            copySequenceOrder: metadata.copySequenceOrder,
            favoriteOrder: metadata.favoriteOrder,
            sensitivity: metadata.sensitivity,
            expiresAt: metadata.expiresAt,
            deletedAt: metadata.deletedAt,
            storedContentKey: metadata.storedContentKey,
            isStoredEncrypted: metadata.isEncrypted
        )
    }

    private static func hydrateBatchRowBody(
        from row: Row,
        header: ClipboardItem,
        metadata: UnsealedClipHeaderMetadata,
        attachment: TagAttachment,
        keys: ClipBookDerivedKeys
    ) throws -> ClipboardItem {
        let bodyText = try decodeStringColumn(
            from: row,
            rowColumn: "bodyText",
            column: .clipContent(.text),
            clipID: metadata.id,
            isEncrypted: metadata.isEncrypted,
            keys: keys
        )
        let bodyQRCodeText = try decodeStringColumn(
            from: row,
            rowColumn: "bodyQRCodeText",
            column: .clipContent(.qrCodeText),
            clipID: metadata.id,
            isEncrypted: metadata.isEncrypted,
            keys: keys
        )
        return header.withLoadedContent(
            text: bodyText,
            qrCodeText: bodyQRCodeText,
            scope: .body,
            tagNames: attachment.tagNames,
            recomputesDerivedMetadata: false
        )
    }

    func decodeBatchRow(
        _ row: Row,
        attachment: TagAttachment,
        hydratesBody: Bool,
        isolatesCorruptEncryptedRows: Bool = true,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> ClipboardItem? {
        guard let metadata = UnsealedClipHeaderMetadata(row: row) else {
            return nil
        }

        do {
            let sealed = try Self.decodeSealedClipHeaderFields(
                from: row,
                clipID: metadata.id,
                isEncrypted: metadata.isEncrypted,
                keys: keys,
                decoder: decoder
            )
            let header = Self.makeStoredHeaderItem(
                metadata: metadata,
                sealed: sealed,
                attachment: attachment
            )
            guard hydratesBody else {
                return header
            }
            return try Self.hydrateBatchRowBody(
                from: row,
                header: header,
                metadata: metadata,
                attachment: attachment,
                keys: keys
            )
        } catch {
            guard metadata.isEncrypted else {
                return nil
            }
            guard isolatesCorruptEncryptedRows else {
                throw error
            }
            return Self.makeCorruptEncryptedPlaceholder(metadata: metadata, attachment: attachment)
        }
    }

    private static func makeCorruptEncryptedPlaceholder(
        metadata: UnsealedClipHeaderMetadata,
        attachment: TagAttachment
    ) -> ClipboardItem {
        ClipboardItem.fromStoredHeader(
            id: metadata.id,
            kind: metadata.kind,
            title: nil,
            textPreview: nil,
            characterCount: 0,
            containsPreviewSecret: true,
            containsRestSecret: true,
            hasRecognizedText: false,
            hasQRCodeText: false,
            isSVGText: false,
            hasFormatting: false,
            htmlDigest: nil,
            imageDigest: nil,
            imageWidth: nil,
            imageHeight: nil,
            assetPath: nil,
            filePaths: [],
            sourceAppName: metadata.sourceAppName,
            sourceBundleIdentifier: metadata.sourceBundleIdentifier,
            copiedAt: metadata.copiedAt,
            firstCopiedAt: metadata.firstCopiedAt,
            byteSize: metadata.byteSize,
            isFavorite: metadata.isFavorite,
            tags: attachment.tagIDs,
            tagOrders: attachment.tagOrders,
            copyCount: metadata.copyCount,
            linkPreviewDetails: nil,
            copySequenceID: metadata.copySequenceID,
            copySequenceOrder: metadata.copySequenceOrder,
            favoriteOrder: metadata.favoriteOrder,
            sensitivity: .sensitive,
            expiresAt: metadata.expiresAt,
            deletedAt: metadata.deletedAt,
            storedContentKey: metadata.storedContentKey,
            isCorruptPlaceholder: true
        )
    }

    private static func decodeProtectedLinkPreviewValue(
        _ dbValue: DatabaseValue,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> LinkPreviewDetails? {
        guard let jsonData = try decodeDataValue(
            dbValue,
            column: .clip(.linkPreviewData),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) else {
            return nil
        }
        let details: LinkPreviewDetails
        do {
            details = try decoder.decode(LinkPreviewDetails.self, from: jsonData)
        } catch {
            throw HistoryStoreError.authenticationFailed
        }
        if isEncrypted {
            if let imagePath = details.imagePath, !hasEncryptedAssetExtension(imagePath) {
                throw HistoryStoreError.authenticationFailed
            }
            if let faviconPath = details.faviconPath, !hasEncryptedAssetExtension(faviconPath) {
                throw HistoryStoreError.authenticationFailed
            }
        }
        return details
    }

    private static func decodeProtectedFilePathsValue(
        _ dbValue: DatabaseValue,
        clipID: UUID,
        isEncrypted: Bool,
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) throws -> [String] {
        guard let jsonData = try decodeDataValue(
            dbValue,
            column: .clip(.filePathsData),
            clipID: clipID,
            isEncrypted: isEncrypted,
            keys: keys
        ) else {
            throw HistoryStoreError.authenticationFailed
        }
        if jsonData.count == 2,
           jsonData[jsonData.startIndex] == 0x5B,
           jsonData[jsonData.index(after: jsonData.startIndex)] == 0x5D {
            return []
        }
        do {
            return try decoder.decode([String].self, from: jsonData)
        } catch {
            throw HistoryStoreError.authenticationFailed
        }
    }

    // Positional column layout matching fetchSearchTextBatch's SELECT:
    // 0: id, 1: kind, 2: isEncrypted, 3: sourceAppName, 4: title,
    // 5: filePathsData, 6: linkPreviewData, 7: text, 8: qrCodeText,
    // 9: whether any of columns 4...8 holds an INTEGER or REAL value.
    static func decodeSearchTextForRow(
        _ row: Row,
        clipID: UUID,
        tagIDs: [Int],
        tagNamesByID: [Tag.ID: String],
        keys: ClipBookDerivedKeys,
        decoder: JSONDecoder
    ) -> String {
        let kindRaw: String = row[1] ?? ClipboardKind.text.rawValue
        let kind = ClipboardKind(rawValue: kindRaw) ?? .text
        let isEncrypted = ((row[2] as Int?) ?? 0) != 0
        let sourceAppName: String? = row[3]

        do {
            let title: String?
            let filePaths: [String]
            let linkPreviewDetails: LinkPreviewDetails?
            let text: String?
            let qrCodeText: String?

            if isEncrypted {
                title = try decodeStringValue(
                    row[4],
                    column: .clip(.title),
                    clipID: clipID,
                    isEncrypted: true,
                    keys: keys
                )
                filePaths = try decodeProtectedFilePathsValue(
                    row[5],
                    clipID: clipID,
                    isEncrypted: true,
                    keys: keys,
                    decoder: decoder
                )
                linkPreviewDetails = try decodeProtectedLinkPreviewValue(
                    row[6],
                    clipID: clipID,
                    isEncrypted: true,
                    keys: keys,
                    decoder: decoder
                )
                text = try decodeStringValue(
                    row[7],
                    column: .clipContent(.text),
                    clipID: clipID,
                    isEncrypted: true,
                    keys: keys
                )
                qrCodeText = try decodeStringValue(
                    row[8],
                    column: .clipContent(.qrCodeText),
                    clipID: clipID,
                    isEncrypted: true,
                    keys: keys
                )
            } else {
                // The zero-copy reads below would let SQLite render a numeric
                // value as digits, so a row holding one is rejected up front.
                if ((row[9] as Int?) ?? 0) != 0 {
                    throw HistoryStoreError.authenticationFailed
                }
                title = try decodeUnencryptedString(from: row, atIndex: 4)
                filePaths = try decodeUnencryptedFilePaths(from: row, atIndex: 5, decoder: decoder)
                linkPreviewDetails = try decodeUnencryptedLinkPreview(from: row, atIndex: 6, decoder: decoder)
                text = try decodeUnencryptedString(from: row, atIndex: 7)
                qrCodeText = try decodeUnencryptedString(from: row, atIndex: 8)
            }

            return ClipboardItem.makeSearchText(
                title: title,
                text: text,
                filePaths: kind == .image ? [] : filePaths,
                tagIDs: tagIDs,
                tagNamesByID: tagNamesByID,
                sourceAppName: sourceAppName,
                linkPreviewDetails: linkPreviewDetails,
                qrCodeText: qrCodeText
            )
        } catch {
            return ""
        }
    }

    func fetchFirstMatchingItem(
        in db: Database,
        cursor: RowCursor,
        keys: ClipBookDerivedKeys,
        where predicate: (ClipboardItem) -> Bool
    ) throws -> ClipboardItem? {
        let decoder = Self.makeJSONDecoder()
        var finished = false
        var matched: ClipboardItem?
        while !finished && matched == nil {
            try autoreleasepool {
                var count = 0
                while count < Self.cursorBatchSize {
                    guard let row = try cursor.next() else {
                        finished = true
                        return
                    }
                    count += 1
                    guard let idString: String = row["id"] else {
                        continue
                    }
                    let attachment = try self.fetchTagAttachment(in: db, clipIDString: idString)
                    if let decoded = try self.decodeBatchRow(
                        row,
                        attachment: attachment,
                        hydratesBody: true,
                        keys: keys,
                        decoder: decoder
                    ), predicate(decoded) {
                        matched = decoded
                        return
                    }
                }
            }
        }
        return matched
    }

    func fetchMatchingItem(
        in db: Database,
        kind: ClipboardKind,
        contentKeyBlob: Data,
        keys: ClipBookDerivedKeys
    ) throws -> ClipboardItem? {
        let stmt = try db.cachedStatement(sql: """
            SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText
            FROM clips c
            LEFT JOIN clip_contents cc ON cc.clipId = c.id
            WHERE c.kind = ? AND c.contentKey = ?
            ORDER BY c.deletedAt IS NOT NULL, c.copiedAt DESC
            """)
        let cursor = try Row.fetchCursor(stmt, arguments: [kind.rawValue, contentKeyBlob])
        return try fetchFirstMatchingItem(in: db, cursor: cursor, keys: keys) { !$0.isCorruptPlaceholder }
    }

    func fetchFullItemByID(
        in db: Database,
        id: UUID,
        keys: ClipBookDerivedKeys
    ) throws -> ClipboardItem? {
        let idString = id.uuidString
        let sql = """
            SELECT c.*, cc.text AS bodyText, cc.qrCodeText AS bodyQRCodeText,
                   cc.rtf AS bodyRTF, cc.html AS bodyHTML
            FROM clips c
            LEFT JOIN clip_contents cc ON cc.clipId = c.id
            WHERE c.id = ?
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [idString]) else {
            return nil
        }

        let attachment = try fetchTagAttachment(in: db, clipIDString: idString)
        let decoder = Self.makeJSONDecoder()
        guard let header = try decodeBatchRow(
            row,
            attachment: attachment,
            hydratesBody: false,
            isolatesCorruptEncryptedRows: false,
            keys: keys,
            decoder: decoder
        ) else {
            return nil
        }

        let isEncrypted = ((row["isEncrypted"] as Int?) ?? 0) != 0
        let text = try Self.decodeStringColumn(
            from: row,
            rowColumn: "bodyText",
            column: .clipContent(.text),
            clipID: id,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let qrCodeText = try Self.decodeStringColumn(
            from: row,
            rowColumn: "bodyQRCodeText",
            column: .clipContent(.qrCodeText),
            clipID: id,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let rtfData = try Self.decodeDataColumn(
            from: row,
            rowColumn: "bodyRTF",
            column: .clipContent(.rtf),
            clipID: id,
            isEncrypted: isEncrypted,
            keys: keys
        )
        let html = try Self.decodeStringColumn(
            from: row,
            rowColumn: "bodyHTML",
            column: .clipContent(.html),
            clipID: id,
            isEncrypted: isEncrypted,
            keys: keys
        )

        return header.withLoadedContent(
            text: text,
            qrCodeText: qrCodeText,
            html: html,
            rtfData: rtfData,
            scope: .full,
            tagNames: attachment.tagNames,
            recomputesDerivedMetadata: false
        )
    }

    // MARK: - Tag Query Helpers

    static func fetchAllTags(in db: Database) throws -> [Tag] {
        let cursor = try Row.fetchCursor(
            db,
            sql: "SELECT id, name, color FROM tags ORDER BY name COLLATE NOCASE ASC, id ASC"
        )
        var tags: [Tag] = []
        while let row = try cursor.next() {
            tags.append(Tag(
                id: row["id"],
                name: row["name"],
                color: row["color"]
            ))
        }
        return tags
    }

    func fetchTagAttachments(in db: Database, trashedFilter: Bool) throws -> [String: TagAttachment] {
        let whereClause = trashedFilter ? "WHERE c.deletedAt IS NOT NULL" : "WHERE c.deletedAt IS NULL"

        let sql = """
            SELECT ct.clipId, ct.tagId, ct.sortOrder, t.name
            FROM clip_tags ct
            JOIN tags t ON t.id = ct.tagId
            JOIN clips c ON c.id = ct.clipId
            \(whereClause)
            ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
            """
        let cursor = try Row.fetchCursor(db, sql: sql)
        var map: [String: TagAttachment] = [:]
        while let row = try cursor.next() {
            let clipID: String = row["clipId"]
            map[clipID, default: TagAttachment()].append(row: row)
        }
        return map
    }

    func fetchTagAttachments(
        in db: Database,
        forClipIDStrings clipIDStrings: [String]
    ) throws -> [String: TagAttachment] {
        guard !clipIDStrings.isEmpty else {
            return [:]
        }
        var map: [String: TagAttachment] = [:]
        var offset = 0
        while offset < clipIDStrings.count {
            let end = min(offset + Self.searchInClauseBatchLimit, clipIDStrings.count)
            let batch = Array(clipIDStrings[offset..<end])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let sql = """
                SELECT ct.clipId, ct.tagId, ct.sortOrder, t.name
                FROM clip_tags ct
                JOIN tags t ON t.id = ct.tagId
                WHERE ct.clipId IN (\(placeholders))
                ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
                """
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: StatementArguments(batch))
            while let row = try cursor.next() {
                let clipID: String = row["clipId"]
                map[clipID, default: TagAttachment()].append(row: row)
            }
            offset = end
        }
        return map
    }

    func fetchTagAttachment(in db: Database, clipIDString: String) throws -> TagAttachment {
        let stmt = try db.cachedStatement(sql: """
            SELECT ct.tagId, ct.sortOrder, t.name
            FROM clip_tags ct
            JOIN tags t ON t.id = ct.tagId
            WHERE ct.clipId = ?
            ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
            """)
        let cursor = try Row.fetchCursor(stmt, arguments: [clipIDString])
        var attachment = TagAttachment()
        while let row = try cursor.next() {
            attachment.append(row: row)
        }
        return attachment
    }

    func fetchOrderedTagNames(in db: Database, clipIDString: String) throws -> [String] {
        let stmt = try db.cachedStatement(sql: """
            SELECT t.name
            FROM clip_tags ct
            JOIN tags t ON t.id = ct.tagId
            WHERE ct.clipId = ?
            ORDER BY t.name COLLATE NOCASE ASC, t.id ASC
            """)
        return try String.fetchAll(stmt, arguments: [clipIDString])
    }
}
