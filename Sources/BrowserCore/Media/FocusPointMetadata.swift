import Foundation

/// A rectangle in the displayed, EXIF-oriented image; normalized, with a top-left origin.
public struct FocusRegion: Equatable, Sendable {
    public enum Kind: Sendable { case inFocus, selected, recorded }
    public let rect: CGRect
    public let kind: Kind
    public init(rect: CGRect, kind: Kind) { self.rect = rect; self.kind = kind }
}

public struct FocusPointMetadata: Equatable, Sendable {
    public enum Availability: Sendable { case available, unsupported, notRecorded, manualFocus }
    public let regions: [FocusRegion]
    public let availability: Availability

    public init(regions: [FocusRegion] = [], availability: Availability) {
        self.regions = regions; self.availability = availability
    }

    /// Targeted ExifTool JSON. AF bit masks deliberately keep ExifTool's index conversion.
    public static func decode(_ data: Data) throws -> Self {
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], objects.count == 1 else {
            throw BrowserFailure.message(L10n.text("无法解析对焦点信息。"))
        }
        let tags = objects[0]
        if let error = tags["ExifTool:Error"] as? String { throw BrowserFailure.message(error) }
        let make = (tags["IFD0:Make"] as? String ?? "").uppercased()
        let model = tags["IFD0:Model"] as? String ?? ""
        let orientation = numbers(tags["IFD0:Orientation"])?.first ?? 1
        guard (1...8).contains(orientation), orientation.rounded() == orientation else { return Self(availability: .notRecorded) }
        if make.contains("CANON"), model.uppercased().contains("EOS") { return canon(tags, orientation: orientation) }
        if make.contains("SONY") { return sony(tags, orientation: orientation) }
        return Self(availability: .unsupported)
    }

    private static func canon(_ tags: [String: Any], orientation: Double) -> Self {
        let mode = numbers(tags["Canon:FocusMode"])?.first
        if mode == 3 || mode == 6 || mode == 16 { return Self(availability: .manualFocus) }
        guard let width = numbers(tags["Canon:AFImageWidth"])?.first,
              let height = numbers(tags["Canon:AFImageHeight"])?.first, width > 0, height > 0,
              let count = numbers(tags["Canon:NumAFPoints"])?.first,
              let valid = numbers(tags["Canon:ValidAFPoints"])?.first,
              count >= 1, count <= 4096, valid >= 1, valid <= count,
              count.rounded() == count, valid.rounded() == valid,
              let xs = numbers(tags["Canon:AFAreaXPositions"]), let ys = numbers(tags["Canon:AFAreaYPositions"]),
              xs.count >= Int(valid), ys.count >= Int(valid) else { return Self(availability: .notRecorded) }
        let widths = numbers(tags["Canon:AFAreaWidths"]) ?? numbers(tags["Canon:AFAreaWidth"])
        let heights = numbers(tags["Canon:AFAreaHeights"]) ?? numbers(tags["Canon:AFAreaHeight"])
        guard let widths, let heights, !widths.isEmpty, !heights.isEmpty,
              widths.count == 1 || widths.count >= Int(valid),
              heights.count == 1 || heights.count >= Int(valid) else { return Self(availability: .notRecorded) }
        let focused = indices(tags["Canon:AFPointsInFocus"], limit: Int(valid))
        let selected = indices(tags["Canon:AFPointsSelected"], limit: Int(valid))
        var regions: [FocusRegion] = []
        for index in focused.union(selected).sorted() {
            let w = widths[widths.count == 1 ? 0 : index], h = heights[heights.count == 1 ? 0 : index]
            guard w > 0, h > 0, w <= width, h <= height else { continue }
            let rect = CGRect(x: (width / 2 + xs[index] - w / 2) / width,
                              y: (height / 2 - ys[index] - h / 2) / height, width: w / width, height: h / height)
            if let rect = oriented(rect, orientation: Int(orientation)) {
                regions.append(FocusRegion(rect: rect, kind: focused.contains(index) ? .inFocus : .selected))
            }
        }
        return Self(regions: regions, availability: regions.isEmpty ? .notRecorded : .available)
    }

    private static func sony(_ tags: [String: Any], orientation: Double) -> Self {
        guard let mode = numbers(tags["Sony:FocusMode"])?.first else { return Self(availability: .notRecorded) }
        if mode == 0 { return Self(availability: .manualFocus) }
        guard [2, 3, 4, 6, 7].contains(mode),
              let location = numbers(tags["Sony:FocusLocation"]) ?? numbers(tags["Sony:FocusLocation2"]),
              location.count == 4, location[0] > 0, location[1] > 0,
              let size = numbers(tags["Sony:FocusFrameSize"]), size.count == 3, size[2] > 0,
              size[0] > 0, size[1] > 0, size[0] <= location[0], size[1] <= location[1],
              (0...location[0]).contains(location[2]), (0...location[1]).contains(location[3]) else {
            // FocusLocation alone may be a default centre used for playback zoom.
            return Self(availability: .notRecorded)
        }
        let rect = CGRect(x: (location[2] - size[0] / 2) / location[0],
                          y: (location[3] - size[1] / 2) / location[1],
                          width: size[0] / location[0], height: size[1] / location[1])
        guard let rect = oriented(rect, orientation: Int(orientation)) else { return Self(availability: .notRecorded) }
        return Self(regions: [FocusRegion(rect: rect, kind: .recorded)], availability: .available)
    }

    private static func numbers(_ value: Any?) -> [Double]? {
        let values: [Double]
        if let number = value as? NSNumber { values = [number.doubleValue] }
        else if let array = value as? [NSNumber] { values = array.map(\.doubleValue) }
        else if let string = value as? String {
            let tokens = string.split { $0.isWhitespace || $0 == "," }
            values = tokens.compactMap { Double($0) }
            guard values.count == tokens.count else { return nil }
        } else { return nil }
        return !values.isEmpty && values.allSatisfy(\.isFinite) ? values : nil
    }

    private static func indices(_ value: Any?, limit: Int) -> Set<Int> {
        Set((numbers(value) ?? []).compactMap { value in
            guard value >= 0, value < Double(limit), value.rounded() == value else { return nil }
            return Int(value)
        })
    }

    private static func oriented(_ rect: CGRect, orientation: Int) -> CGRect? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        // A frame may touch the edge, but reject an off-image centre rather than inventing one.
        guard unit.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        let result: CGRect
        switch orientation {
        case 2: result = CGRect(x: 1-x-w, y: y, width: w, height: h)
        case 3: result = CGRect(x: 1-x-w, y: 1-y-h, width: w, height: h)
        case 4: result = CGRect(x: x, y: 1-y-h, width: w, height: h)
        case 5: result = CGRect(x: y, y: x, width: h, height: w)
        case 6: result = CGRect(x: 1-y-h, y: x, width: h, height: w)
        case 7: result = CGRect(x: 1-y-h, y: 1-x-w, width: h, height: w)
        case 8: result = CGRect(x: y, y: 1-x-w, width: h, height: w)
        default: result = rect
        }
        let clipped = result.intersection(unit)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }
}
