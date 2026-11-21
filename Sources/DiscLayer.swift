import SwiftUI
import AppKit
import QuartzCore

// La rotation des disques est confiée à Core Animation : le serveur graphique de macOS
// fait tourner l'image tout seul, l'app ne recalcule rien à chaque image (≈ 0 % CPU).

final class SpinLayerView: NSView {
    let disc = CALayer()
    private var angle: CGFloat = 0 // radians, sens horaire
    private var playing = false
    private var speed: Double = 45 // degrés / seconde
    private var scratchBase: CGFloat?
    private var configured = false
    private let ramp: CFTimeInterval = 1.3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(disc)
        disc.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // les gestes restent à SwiftUI

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.bounds = bounds
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        disc.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Angle affiché à l'écran en ce moment.
    private func currentAngle() -> CGFloat {
        if let v = disc.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat { return -v }
        return angle
    }

    private func setStatic(_ a: CGFloat) {
        disc.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.setValue(-a, forKeyPath: "transform.rotation.z") // CA tourne dans le sens trigo
        CATransaction.commit()
        angle = a
    }

    func apply(playing newPlaying: Bool, speed newSpeed: Double) {
        guard scratchBase == nil else { playing = newPlaying; speed = newSpeed; return }
        if configured, newPlaying == playing, newSpeed == speed { return }
        let wasPlaying = configured && playing
        let oldSpeed = speed
        configured = true
        playing = newPlaying
        speed = newSpeed

        let a0 = currentAngle()
        if newPlaying {
            let v = CGFloat(newSpeed * .pi / 180)
            let rampAngle = wasPlaying ? 0 : v * CGFloat(ramp) / 2
            setStatic(a0)
            let now = CACurrentMediaTime()
            if rampAngle > 0 {
                // Démarrage progressif comme une vraie platine
                let up = CABasicAnimation(keyPath: "transform.rotation.z")
                up.fromValue = -a0
                up.toValue = -(a0 + rampAngle)
                up.duration = ramp
                up.timingFunction = CAMediaTimingFunction(name: .easeIn)
                up.fillMode = .forwards
                up.isRemovedOnCompletion = false
                disc.add(up, forKey: "rampUp")
            }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = -(a0 + rampAngle)
            spin.byValue = -2 * CGFloat.pi
            spin.duration = 2 * .pi / Double(v)
            spin.repeatCount = .infinity
            if rampAngle > 0 { spin.beginTime = disc.convertTime(now + ramp, from: nil) }
            disc.add(spin, forKey: "spin")
        } else if wasPlaying {
            // Ralentissement en douceur jusqu'à l'arrêt
            let v = CGFloat(oldSpeed * .pi / 180)
            let end = a0 + v * CGFloat(ramp) / 2
            setStatic(end)
            let down = CABasicAnimation(keyPath: "transform.rotation.z")
            down.fromValue = -a0
            down.toValue = -end
            down.duration = ramp
            down.timingFunction = CAMediaTimingFunction(name: .easeOut)
            disc.add(down, forKey: "rampDown")
        } else {
            setStatic(a0)
        }
    }

    /// Scratch : `total` en degrés depuis le début du geste, `nil` quand on relâche.
    func scratch(_ total: Double?) {
        if let total {
            if scratchBase == nil { scratchBase = currentAngle() }
            setStatic(scratchBase! + CGFloat(total * .pi / 180))
        } else if scratchBase != nil {
            scratchBase = nil
            let p = playing
            playing = false // force un redémarrage progressif
            apply(playing: p, speed: speed)
        }
    }
}

struct SpinningImage: NSViewRepresentable {
    let image: CGImage?
    let playing: Bool
    let speed: Double
    var scratch: Double?

    func makeNSView(context: Context) -> SpinLayerView { SpinLayerView() }

    func updateNSView(_ view: SpinLayerView, context: Context) {
        if (view.disc.contents as AnyObject?) !== image { view.disc.contents = image }
        view.apply(playing: playing, speed: speed)
        view.scratch(scratch)
    }
}

// MARK: - Image de la face tournante (rendue une seule fois par pochette)

struct DiscFace: View {
    let image: NSImage?
    let size: CGFloat
    let accent: Color
    let style: DiscStyle
    let labelRatio: CGFloat

    var body: some View {
        ZStack {
            switch style {
            case .record:
                Circle().fill(RadialGradient(
                    colors: [Color(white: 0.10), Color(white: 0.045), Color(white: 0.075), Color(white: 0.025)],
                    center: .center, startRadius: 0, endRadius: size / 2))
                Grooves(inner: labelRatio, dark: false)
                artwork
                    .frame(width: size * labelRatio, height: size * labelRatio)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: max(1, size * 0.006))
                        .frame(width: size * labelRatio, height: size * labelRatio))
            case .picture:
                artwork
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                Grooves(inner: 0.30, dark: true)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    @ViewBuilder private var artwork: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
        } else {
            ZStack {
                AngularGradient(colors: [accent, accent.opacity(0.35), .black, accent.opacity(0.6), accent],
                                center: .center)
                Image(systemName: "music.note")
                    .font(.system(size: size * (style == .record ? labelRatio : 0.6) * 0.35, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

@MainActor
enum DiscFaceCache {
    private static var cache: [String: CGImage] = [:]
    private static var order: [String] = []

    static func image(artwork: NSImage?, size: CGFloat, accent: NSColor, style: DiscStyle, labelRatio: CGFloat) -> CGImage? {
        let artKey = artwork.map { "\(ObjectIdentifier($0).hashValue)" } ?? "none-\(accent.description)"
        let key = "\(artKey)|\(Int(size))|\(style.rawValue)|\(labelRatio)"
        if let hit = cache[key] { return hit }

        let renderer = ImageRenderer(content: DiscFace(image: artwork, size: size, accent: Color(nsColor: accent),
                                                       style: style, labelRatio: labelRatio))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        cache[key] = cg
        order.append(key)
        if order.count > 8 { cache.removeValue(forKey: order.removeFirst()) }
        return cg
    }
}
