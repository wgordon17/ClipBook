import Foundation

extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension StringProtocol where SubSequence == Substring {
    nonisolated func scalarBoundedUTF16Prefix(_ maxUTF16Length: Int) -> Substring {
        let slice = self[...]
        guard slice.utf8.count > maxUTF16Length else {
            return slice
        }

        let scalars = slice.unicodeScalars
        var end = scalars.startIndex
        var utf16Count = 0
        while end < scalars.endIndex {
            let nextCount = utf16Count + scalars[end].utf16.count
            if nextCount > maxUTF16Length, end > scalars.startIndex {
                break
            }
            utf16Count = nextCount
            scalars.formIndex(after: &end)
            if utf16Count >= maxUTF16Length {
                break
            }
        }
        return slice[slice.startIndex..<end]
    }
}
