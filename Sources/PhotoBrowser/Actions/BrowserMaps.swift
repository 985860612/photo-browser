import MapKit
import CoreLocation
import BrowserCore

@MainActor enum PhotoMapLauncher {
    private static var launchTask: Task<Void, Never>?

    static func item(location: PhotoLocation, name: String, sourceSystem: PhotoCoordinateSystem = .wgs84,
                     mainlandChinaMap: Bool = false) throws -> MKMapItem {
        guard let converted = sourceSystem.converting(location, to: mainlandChinaMap ? .gcj02 : .wgs84) else {
            throw BrowserFailure.message(L10n.text("坐标转换失败，请检查照片坐标和坐标系设置。"))
        }
        let coordinate = CLLocationCoordinate2D(latitude: converted.latitude, longitude: converted.longitude)
        let item: MKMapItem
        #if compiler(>=6.2)
        if #available(macOS 26, *) { item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil) }
        else { item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate)) }
        #else
        item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        #endif
        item.name = name
        return item
    }

    static func resolvedItem(location: PhotoLocation, name: String,
                             sourceSystem: PhotoCoordinateSystem = .wgs84,
                             mapRegion: String = Locale.current.region?.identifier ?? "",
                             countryLookup: (CLLocation) async throws -> String? = countryCode) async throws -> MKMapItem {
        // A region setting alone does not establish the photo's country. In particular,
        // Hong Kong, Macau, Taiwan and nearby countries must not receive a mainland shift.
        guard let wgs = sourceSystem.converting(location, to: .wgs84) else {
            throw BrowserFailure.message(L10n.text("坐标转换失败，请检查照片坐标和坐标系设置。"))
        }
        let mayUseGCJ02 = mapRegion == "CN" && (0...56).contains(wgs.latitude)
            && (72...138).contains(wgs.longitude)
        var mainlandChinaMap = false
        if mayUseGCJ02 {
            guard let country = try await countryLookup(CLLocation(latitude: wgs.latitude, longitude: wgs.longitude)) else {
                throw CLError(.geocodeFoundNoResult)
            }
            mainlandChinaMap = country == "CN"
        }
        return try item(location: location, name: name, sourceSystem: sourceSystem, mainlandChinaMap: mainlandChinaMap)
    }

    private static func countryCode(_ location: CLLocation) async throws -> String? {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            return try await request.mapItems.first?.addressRepresentations?.region?.identifier
        } else {
            return try await legacyCountryCode(location)
        }
        #else
        return try await legacyCountryCode(location)
        #endif
    }

    @available(macOS, introduced: 14, deprecated: 26)
    private static func legacyCountryCode(_ location: CLLocation) async throws -> String? {
        try await CLGeocoder().reverseGeocodeLocation(location).first?.isoCountryCode
    }

    static func open(name: String, prepare: @escaping () async throws -> (PhotoLocation, PhotoCoordinateSystem),
                     onFailure: @escaping (Error) -> Void) {
        guard launchTask == nil else { return }
        launchTask = Task {
            defer { launchTask = nil }
            do {
                let (location, system) = try await prepare()
                let target = try await resolvedItem(location: location, name: name, sourceSystem: system)
                if !openItem(target) {
                    throw BrowserFailure.message(L10n.text("无法打开地图，请确认已安装苹果地图。"))
                }
            } catch is CancellationError { }
            catch { onFailure(error) }
        }
    }

    private static func openItem(_ target: MKMapItem) -> Bool {
        target.openInMaps(launchOptions: nil)
    }
}

extension BrowserStore {
    func openFocusedLocation() {
        guard let asset = focusedAsset, asset.metadata?.location != nil else {
            report(BrowserFailure.message(L10n.text("此照片没有有效的 GPS 坐标。"))); return
        }
        PhotoMapLauncher.open(name: asset.name, prepare: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.locationForMap(asset)
        }) { [weak self] error in self?.report(error) }
    }

    func locationForMap(_ asset: PhotoAsset) async throws -> (PhotoLocation, PhotoCoordinateSystem) {
        var metadata = assets.first { $0.id == asset.id }?.metadata
        if metadata?.gpsMapDatumRead != true {
            var seen: Set<String> = []
            for file in [asset.metadataFile, asset.preferred] + asset.imageFiles where seen.insert(file.id).inserted {
                let header = try await thumbnails.sourceMetadata(file)
                try Task.checkCancellation()
                guard assets.contains(where: { $0.id == asset.id }) else { throw CancellationError() }
                updateMetadata(asset.id, value: header)
                metadata = assets.first { $0.id == asset.id }?.metadata
                if metadata?.gpsMapDatumRead == true { break }
            }
        }
        guard let metadata, let location = metadata.location else {
            throw BrowserFailure.message(L10n.text("此照片没有有效的 GPS 坐标。"))
        }
        return (location, metadata.coordinateSystem(preferred: preferredCoordinateSystem))
    }
}
