#if canImport(UIKit)
import SwiftUI
import UIKit

/// What a marker shows inside its circle. The marker has no fill of its own: the content decides.
public enum MarkerContent: Sendable {
    /// A small filled circle in the accent colour.
    case dot
    /// A number.
    case count(Int)
    /// A picture, clipped to a circle.
    case image(UIImage)
    /// An image drawn on a fill colour.
    case symbol(UIImage, fill: Color)
    /// A red-white-red plate with a short text, for example a trail number.
    case plate(String)
}
#endif
