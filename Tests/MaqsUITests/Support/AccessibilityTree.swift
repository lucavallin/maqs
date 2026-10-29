#if canImport(UIKit)
import Foundation
import Testing
import UIKit

/// What VoiceOver finds in a window, read in a unit test.
///
/// SwiftUI builds its accessibility tree only while app accessibility is on, which VoiceOver or UI automation turns on
/// and nothing in a unit test does, and no public API turns it on: without it a hosting view has no accessibility
/// elements at all. ``read(_:)`` turns it on with libAccessibility's private `_AXSApplicationAccessibilitySetEnabled`
/// and sets it back before returning, because the simulator keeps the setting across runs (seen 2026-10-28: a run that
/// did not set it back left it on for the next). Everything in between runs synchronously on the main actor, where
/// SwiftUI answers at once: the tree is there right after layout, and a button's action shows in the next walk.
@MainActor enum AccessibilityTree {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void

    /// Runs `body` with app accessibility on, then sets it back to what it was.
    static func read<T>(_ body: () throws -> T) throws -> T {
        let library = try #require(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), "libAccessibility is missing")
        let isEnabled = unsafeBitCast(
            try #require(dlsym(library, "_AXSApplicationAccessibilityEnabled"), "no app accessibility getter"),
            to: Getter.self)
        let setEnabled = unsafeBitCast(
            try #require(dlsym(library, "_AXSApplicationAccessibilitySetEnabled"), "no app accessibility setter"),
            to: Setter.self)
        let before = isEnabled()
        setEnabled(1)
        defer { setEnabled(before) }
        return try body()
    }

    /// The accessibility elements under `object` in VoiceOver's order: an object whose elements are hidden is skipped
    /// with everything under it, an element is listed, anything else is entered, through its accessibility children
    /// (the `accessibilityElements` array, or the older count-and-index container calls, which `MLNMapView` answers)
    /// or, for a view without any, its subviews. Call it inside ``read(_:)``.
    static func elements(in object: NSObject) -> [NSObject] {
        if object.accessibilityElementsHidden { return [] }
        if object.isAccessibilityElement { return [object] }
        var children = (object.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        if children.isEmpty {
            let count = object.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                children = (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
        }
        if children.isEmpty, let view = object as? UIView { children = view.subviews }
        return children.flatMap(elements(in:))
    }
}
#endif
