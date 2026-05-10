import Foundation
import ImageIO
import CoreGraphics

/// Pulls EXIF metadata out of an image file. Per DESIGN.md §5.15, we pre-fill
/// the attachment's `dateTaken` and `locationTaken` from EXIF when present so
/// the user doesn't have to retype info that's already on the photo.
///
/// All work is on-disk and synchronous — call sites are off the main actor.
nonisolated struct EXIFExtractor {
    struct EXIFData: Sendable {
        var dateTaken: Date?
        var locationTaken: String?     // "lat,lon" string for now; reverse-geocoding deferred.
    }

    /// Extract EXIF date + GPS from an image file URL. Returns nil if no
    /// readable metadata (e.g. PNG with no EXIF, or non-image file).
    static func extract(from url: URL) -> EXIFData? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            return nil
        }

        var data = EXIFData()
        var hasAny = false

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let parsed = parseEXIFDate(dateString) {
            data.dateTaken = parsed
            hasAny = true
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            let signedLat = latRef.uppercased() == "S" ? -latitude : latitude
            let signedLon = lonRef.uppercased() == "W" ? -longitude : longitude
            data.locationTaken = String(format: "%.6f,%.6f", signedLat, signedLon)
            hasAny = true
        }

        return hasAny ? data : nil
    }

    /// EXIF format is "yyyy:MM:dd HH:mm:ss" — distinct from ISO 8601, so we
    /// keep our own formatter rather than reusing one elsewhere.
    private static func parseEXIFDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: string)
    }
}
