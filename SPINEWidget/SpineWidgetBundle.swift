//
//  SpineWidgetBundle.swift
//  SPINEWidget
//

import WidgetKit
import SwiftUI

@main
struct SpineWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpineWidget()
    }
}

struct SpineWidget: Widget {
    // Widget identity on the home screen. Must stay "WellReadWidget" forever:
    // changing it removes every widget readers have already placed.
    let kind: String = "WellReadWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpineTimelineProvider()) { entry in
            SpineWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("SPINE")
        .description("Your reading stack and what people you follow are reading now.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
