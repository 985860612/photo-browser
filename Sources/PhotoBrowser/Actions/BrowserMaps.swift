import MapKit
import CoreLocation
import BrowserCore

@MainActor enum PhotoMapLauncher {
    static func item(location: PhotoLocation, name: String) -> MKMapItem {
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        let item: MKMapItem
        #if compiler(>=6.2)
        if #available(macOS 26, *) { item = MKMapItem(location: CLLocation(latitude: location.latitude, longitude: location.longitude), address: nil) }
        else { item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate)) }
        #else
        item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        #endif
        item.name = name
        return item
    }
}

extension BrowserStore {
    func openFocusedLocation() {
        guard let asset = focusedAsset, let location = asset.metadata?.location else {
            report(BrowserFailure.message(L10n.text("此照片没有有效的 GPS 坐标。"))); return
        }
        if !PhotoMapLauncher.item(location: location, name: asset.name).openInMaps(launchOptions: nil) {
            report(BrowserFailure.message(L10n.text("无法打开地图，请确认已安装苹果地图。")))
        }
    }
}
