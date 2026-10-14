import Foundation

/// Preserve requested widths while a smaller window temporarily constrains them.
public struct BrowserPanelLayout {
    public static let directoryRange = 220.0...420.0
    public static let inspectorRange = 215.0...420.0
    public let directory: Double
    public let inspector: Double
    public init(available: Double, directoryWidth: Double, inspectorWidth: Double,
                showDirectory: Bool, showInspector: Bool) {
        let separators = Double((showDirectory ? 1 : 0) + (showInspector ? 1 : 0)) * 6
        let room = max(0, available - 550 - separators)
        let rightMinimum = showInspector ? Self.inspectorRange.lowerBound : 0
        directory = showDirectory ? min(Self.clamp(directoryWidth, to: Self.directoryRange, fallback: 250),
                                        max(Self.directoryRange.lowerBound, room - rightMinimum)) : 0
        inspector = showInspector ? min(Self.clamp(inspectorWidth, to: Self.inspectorRange, fallback: 240),
                                        max(Self.inspectorRange.lowerBound, room - directory)) : 0
    }
    public static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
