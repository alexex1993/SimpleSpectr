//
//  MarkersStore.swift
//  SimpleSpectr
//
//  Session markers/annotations placed on the spectrogram time axis (à la Sonic
//  Visualiser). Markers live in memory for the currently open file and are
//  cleared when a different file is loaded.
//

import Foundation
import SwiftUI
import Combine

struct Marker: Identifiable, Equatable {
    let id = UUID()
    var time: Double      // seconds
    var label: String
}

@MainActor
final class MarkersStore: ObservableObject {
    /// Markers sorted by time so the on-screen flags and the list agree.
    @Published private(set) var markers: [Marker] = []

    /// Add a marker at `time` (seconds). If `label` is empty a default
    /// "Marker N" name is assigned. Returns the new marker's id.
    @discardableResult
    func add(at time: Double, label: String = "") -> UUID {
        let name = label.isEmpty ? L("markers.defaultLabel", markers.count + 1) : label
        let marker = Marker(time: max(0, time), label: name)
        markers.append(marker)
        markers.sort { $0.time < $1.time }
        return marker.id
    }

    func remove(_ id: UUID) {
        markers.removeAll { $0.id == id }
    }

    func updateLabel(_ id: UUID, to label: String) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[i].label = label
    }

    func clear() {
        markers.removeAll()
    }
}
