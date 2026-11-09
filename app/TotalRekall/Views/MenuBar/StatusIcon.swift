import AppKit

/// Renders the status item's template images: the bear glyph, plus a bottom-right badge per state.
/// States differ by shape, not color. Every result is a template image; the badge sits in a
/// transparent halo cut out of the bear so it reads in both light and dark menu bars.
@MainActor
enum StatusIcon {
    enum Badge { case none, working, attention }

    static let size = NSSize(width: 18, height: 18)

    /// Badge for a view-model icon name. Triangle/exclamation names mean attention; animates means working.
    static func badge(iconName: String, animates: Bool) -> Badge {
        if iconName.hasPrefix("exclamationmark") { return .attention }
        return animates ? .working : .none
    }

    /// Number of frames in the restoring animation (the orbiting dot's positions).
    static let workingFrameCount = 8

    /// `workingFrame` is nil for the static working glyph (centered dot); 0..<workingFrameCount orbits the dot.
    static func image(badge: Badge, description: String, workingFrame: Int? = nil) -> NSImage? {
        guard let bear = NSImage(named: "MenuBarBear") else { return nil }
        let result = NSImage(size: size, flipped: false) { rect in
            bear.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            guard badge != .none else { return true }
            drawBadge(badge, in: rect, workingFrame: workingFrame)
            return true
        }
        result.isTemplate = true
        result.accessibilityDescription = description
        return result
    }

    private static func drawBadge(_ badge: Badge, in rect: NSRect, workingFrame: Int?) {
        let diameter: CGFloat = 8
        let circle = NSRect(x: rect.maxX - diameter, y: rect.minY, width: diameter, height: diameter)
        let halo = circle.insetBy(dx: -1.5, dy: -1.5)

        // Clear halo around the badge so it separates from the bear.
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: halo).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.black.setFill()
        NSColor.black.setStroke()
        switch badge {
        case .working:
            // Ring with a centered dot: reads as "in progress" without motion.
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.6, dy: 0.6))
            ring.lineWidth = 1.2
            ring.stroke()
            if let frame = workingFrame {
                // Animated: a small dot orbits inside the ring.
                let angle = 2 * Double.pi * Double(frame % workingFrameCount) / Double(workingFrameCount)
                let radius: CGFloat = 1.8
                let dot = NSRect(x: circle.midX + radius * CGFloat(cos(angle)) - 1,
                                 y: circle.midY + radius * CGFloat(sin(angle)) - 1, width: 2, height: 2)
                NSBezierPath(ovalIn: dot).fill()
            } else {
                NSBezierPath(ovalIn: circle.insetBy(dx: 2.6, dy: 2.6)).fill()
            }
        case .attention:
            // Solid disc with the exclamation knocked out.
            NSBezierPath(ovalIn: circle).fill()
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: circle.midX - 0.6, y: circle.minY + 3.2, width: 1.2, height: 3.2),
                         xRadius: 0.6, yRadius: 0.6).fill()
            NSBezierPath(ovalIn: NSRect(x: circle.midX - 0.7, y: circle.minY + 1.4, width: 1.4, height: 1.4)).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        case .none:
            break
        }
    }
}

/// Drives the restoring animation. Runs a timer only while a restore is in progress and Reduce Motion is
/// off; every other state (idle, attention, success, failure, Reduce Motion on) has no timer at all.
@MainActor
final class StatusIconAnimator {
    enum Mode: Equatable { case idle, animating, staticWorking }

    static let frameInterval: TimeInterval = 0.125

    private(set) var mode: Mode = .idle
    private(set) var frame = 0
    private(set) var reduceMotion: Bool
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var isWorking = false
    private let reduceMotionProvider: @MainActor () -> Bool
    private let onChange: @MainActor () -> Void

    var isTimerActive: Bool { timer != nil }

    /// Pass `observeSystem: false` in tests to skip the NSWorkspace notification.
    init(reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         observeSystem: Bool = true,
         onChange: @escaping @MainActor () -> Void) {
        self.reduceMotionProvider = reduceMotion
        self.reduceMotion = reduceMotion()
        self.onChange = onChange
        if observeSystem {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reduceMotionMayHaveChanged() }
            }
        }
    }

    /// Call on every view-model change. `working` is true only while a restore is in progress.
    func setWorking(_ working: Bool) {
        isWorking = working
        apply()
    }

    func reduceMotionMayHaveChanged() {
        reduceMotion = reduceMotionProvider()
        apply()
    }

    /// Advances one frame. The timer calls this; tests call it directly.
    func tick() {
        guard mode == .animating else { return }
        frame = (frame + 1) % StatusIcon.workingFrameCount
        onChange()
    }

    /// Stops the timer and drops the observer (app termination / teardown).
    func shutDown() {
        isWorking = false
        stopTimer()
        mode = .idle
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    private func apply() {
        let previous = mode
        if !isWorking {
            mode = .idle
        } else {
            mode = reduceMotion ? .staticWorking : .animating
        }
        if mode == .animating {
            if timer == nil { startTimer() }
        } else {
            stopTimer()
            frame = 0
        }
        if previous != mode { onChange() }
    }

    private func startTimer() {
        let newTimer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
