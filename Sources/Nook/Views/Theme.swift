import NookCore
import SwiftUI

/// Nook's visual language: quiet surfaces, one accent, color reserved for meaning (accounts and tags).
enum Theme {
    /// Sea green, from the pebble icon.
    static let accent = Color(red: 0.13, green: 0.55, blue: 0.47)

    /// Muted, distinguishable hues for accounts and tags. They hold up in light and dark mode.
    static let palette: [Color] = [
        Color(red: 0.36, green: 0.37, blue: 0.94), // indigo
        Color(red: 0.05, green: 0.58, blue: 0.53), // teal
        Color(red: 0.91, green: 0.45, blue: 0.13), // orange
        Color(red: 0.86, green: 0.25, blue: 0.53), // pink
        Color(red: 0.16, green: 0.62, blue: 0.33), // green
        Color(red: 0.58, green: 0.33, blue: 0.89), // purple
        Color(red: 0.11, green: 0.53, blue: 0.85), // blue
        Color(red: 0.86, green: 0.24, blue: 0.24), // red
        Color(red: 0.75, green: 0.56, blue: 0.05), // amber
    ]

    static func color(_ index: Int) -> Color {
        palette[((index % palette.count) + palette.count) % palette.count]
    }

    /// A stable color for a person, so the same sender always gets the same avatar.
    static func color(for email: String) -> Color {
        let hash = email.lowercased().unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }
        return color(abs(hash))
    }

    static let rowHeight: CGFloat = 40
    static let readerWidth: CGFloat = 760
    static let corner: CGFloat = 8
}

extension Date {
    /// "9:41 AM" today, "Mon" this week, "Mar 3" this year, otherwise "3/3/24".
    var listLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 6 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(date: .numeric, time: .omitted)
    }
}
