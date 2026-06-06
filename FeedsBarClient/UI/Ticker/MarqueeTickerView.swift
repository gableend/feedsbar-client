import SwiftUI
import AppKit
import QuartzCore

/// The horizontal gap between ticker items, and the gap stitched between the
/// strip and its duplicate so the loop seam is invisible.
private let tickerItemSpacing: CGFloat = 60

// MARK: - SwiftUI bridge

/// A marquee that scrolls a strip of `TickerRow`s by animating a CALayer's
/// translation on the render server.
///
/// The previous implementation rebuilt ~15 SwiftUI rows 60×/sec (first via a
/// Combine timer mutating @Published state, then via TimelineView). Either way
/// the per-frame view rebuild kept the main thread busy. Here the row content
/// is rendered **once** into an NSHostingView; Core Animation interpolates the
/// scroll on the WindowServer, so the app's main thread stays near-idle.
///
/// Seamless looping is done the classic way: the strip is laid out twice,
/// end to end, and the track is translated by exactly one strip-plus-seam
/// width before repeating — at which point the duplicate sits where the
/// original began, so the wrap is invisible.
struct MarqueeTickerView: NSViewRepresentable {
    /// Pre-ordered items (shuffle/latest is resolved by the caller and kept
    /// stable across redraws — never re-shuffle here or the strip would churn).
    let items: [FeedItem]
    let size: Int
    let speed: Double

    func makeNSView(context: Context) -> MarqueeNSView {
        let view = MarqueeNSView()
        view.apply(items: items, size: size, speed: speed)
        return view
    }

    func updateNSView(_ nsView: MarqueeNSView, context: Context) {
        nsView.apply(items: items, size: size, speed: speed)
    }

    static func dismantleNSView(_ nsView: MarqueeNSView, coordinator: ()) {
        nsView.stop()
    }
}

// MARK: - AppKit marquee

final class MarqueeNSView: NSView {
    private let track = NSView()
    private var hostA: NSHostingView<AnyView>?
    private var hostB: NSHostingView<AnyView>?

    private var stripWidth: CGFloat = 0
    private var stripHeight: CGFloat = 0
    private var itemKey: [String] = []
    private var renderedSize: Int = -1
    private var speed: Double = 1

    /// True while the pointer is over the ticker. Hover pauses auto-scroll and,
    /// crucially, freezes the model layer so SwiftUI hit-testing (tap-to-open)
    /// lines up with what's on screen — during the CA animation the model and
    /// presentation layers diverge, so clicks are only trusted while paused.
    private var hovering = false

    /// Current translation when no animation is attached (paused / scrubbing).
    private var modelTx: CGFloat = 0

    private let animationKey = "marquee"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        track.wantsLayer = true
        addSubview(track)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private var loopDistance: CGFloat { stripWidth + tickerItemSpacing }

    // MARK: Configuration from SwiftUI

    func apply(items: [FeedItem], size: Int, speed: Double) {
        let key = items.map(\.id)
        if key != itemKey || size != renderedSize {
            itemKey = key
            renderedSize = size
            rebuildStrip(items: items, size: size)
        }
        setSpeed(speed)
        setRunning(!hovering)
    }

    func stop() {
        track.layer?.removeAnimation(forKey: animationKey)
    }

    // MARK: Strip construction

    private func rebuildStrip(items: [FeedItem], size: Int) {
        hostA?.removeFromSuperview()
        hostB?.removeFromSuperview()
        hostA = nil
        hostB = nil

        guard !items.isEmpty else {
            stripWidth = 0
            stripHeight = 0
            return
        }

        // One immutable copy of the row strip, hosted twice. TickerRow widths
        // are content-driven (.fixedSize), and favicons/thumbnails load into
        // fixed-size frames, so the measured width is stable after first layout.
        let strip = AnyView(
            HStack(spacing: tickerItemSpacing) {
                ForEach(items) { item in
                    TickerRow(item: item, size: size)
                }
            }
            .fixedSize()
        )

        let a = NSHostingView(rootView: strip)
        a.layoutSubtreeIfNeeded()
        let fitting = a.fittingSize
        stripWidth = fitting.width
        stripHeight = fitting.height

        let b = NSHostingView(rootView: strip)
        for host in [a, b] {
            host.frame = CGRect(x: 0, y: 0, width: stripWidth, height: stripHeight)
        }
        a.frame.origin = .zero
        b.frame.origin = CGPoint(x: loopDistance, y: 0)

        track.addSubview(a)
        track.addSubview(b)
        hostA = a
        hostB = b

        modelTx = 0
        layoutTrack()
        applyModelTranslation()
    }

    private func layoutTrack() {
        guard stripHeight > 0 else { return }
        // Center the strip vertically; width spans both copies plus the seam.
        let y = ((bounds.height - stripHeight) / 2).rounded()
        track.frame = CGRect(x: 0, y: y, width: stripWidth * 2 + tickerItemSpacing, height: stripHeight)
    }

    override func layout() {
        super.layout()
        layoutTrack()
    }

    // MARK: Animation

    private func setRunning(_ running: Bool) {
        guard stripWidth > 0 else { return }
        if running {
            if track.layer?.animation(forKey: animationKey) == nil {
                startAnimation(from: modelTx)
            }
        } else {
            // Freeze: capture where the strip actually is on screen, pin the
            // model there, and drop the animation so hit-testing is accurate.
            if let presented = track.layer?.presentation()?
                .value(forKeyPath: "transform.translation.x") as? CGFloat {
                modelTx = normalize(presented)
            }
            track.layer?.removeAnimation(forKey: animationKey)
            applyModelTranslation()
        }
    }

    private func startAnimation(from start: CGFloat) {
        guard stripWidth > 0, let layer = track.layer else { return }
        let s = normalize(start)
        modelTx = s
        applyModelTranslation()

        let pointsPerSecond = max(1.0, 60.0 * speed)
        let anim = CABasicAnimation(keyPath: "transform.translation.x")
        anim.fromValue = s
        anim.toValue = s - loopDistance          // exactly one period — seamless wrap
        anim.duration = Double(loopDistance) / pointsPerSecond
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: animationKey)
    }

    private func setSpeed(_ newSpeed: Double) {
        guard newSpeed != speed else { return }
        speed = newSpeed
        // Restart from the current on-screen position so a speed change doesn't
        // jump. If paused, the new speed simply applies on the next resume.
        if track.layer?.animation(forKey: animationKey) != nil {
            let current = (track.layer?.presentation()?
                .value(forKeyPath: "transform.translation.x") as? CGFloat) ?? modelTx
            track.layer?.removeAnimation(forKey: animationKey)
            startAnimation(from: current)
        }
    }

    private func applyModelTranslation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.layer?.setValue(modelTx, forKeyPath: "transform.translation.x")
        CATransaction.commit()
    }

    /// Fold any translation back into (-loopDistance, 0]. Because the two strip
    /// copies are identical, shifting by a whole period is visually a no-op, so
    /// this keeps the value bounded without any visible jump.
    private func normalize(_ x: CGFloat) -> CGFloat {
        guard loopDistance > 0 else { return 0 }
        var v = x.truncatingRemainder(dividingBy: loopDistance)
        if v > 0 { v -= loopDistance }
        return v
    }

    // MARK: Hover (pause) + manual scrub

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        setRunning(false)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        setRunning(true)
    }

    // Drag + trackpad scrub. Only active while paused (i.e. hovering), where the
    // model layer is the source of truth and moves the strip immediately.
    override func mouseDragged(with event: NSEvent) {
        guard track.layer?.animation(forKey: animationKey) == nil else { return }
        modelTx = normalize(modelTx + event.deltaX)
        applyModelTranslation()
    }

    override func scrollWheel(with event: NSEvent) {
        guard track.layer?.animation(forKey: animationKey) == nil else {
            super.scrollWheel(with: event)
            return
        }
        let dx = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        modelTx = normalize(modelTx + dx)
        applyModelTranslation()
    }
}
