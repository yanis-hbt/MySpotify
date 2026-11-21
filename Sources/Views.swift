import SwiftUI
import AppKit

// MARK: - Réglages

enum DiscStyle: String, CaseIterable {
    case record   // vinyle noir, pochette en étiquette centrale
    case picture  // « picture disc » : la pochette couvre tout le disque

    var title: String { self == .record ? "Vinyle noir" : "Picture disc (pochette)" }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var style: DiscStyle { didSet { d.set(style.rawValue, forKey: "discStyle") } }
    @Published var showTonearm: Bool { didSet { d.set(showTonearm, forKey: "showTonearm") } }
    @Published var desktopScale: Double { didSet { d.set(desktopScale, forKey: "desktopScale") } }
    @Published var spinSpeed: Double { didSet { d.set(spinSpeed, forKey: "spinSpeed") } }
    @Published var waveIntensity: Double { didSet { d.set(waveIntensity, forKey: "waveIntensity") } }
    @Published var desktopLyrics: Bool { didSet { d.set(desktopLyrics, forKey: "desktopLyrics") } }
    @Published var hideInFullscreen: Bool { didSet { d.set(hideInFullscreen, forKey: "hideInFullscreen") } }

    static let scales: [(String, Double)] = [("Petit", 0.8), ("Moyen", 1.0), ("Grand", 1.2)]
    static let speeds: [(String, Double)] = [("Douce", 45), ("33 tours", 200), ("45 tours", 270)]
    static let intensities: [(String, Double)] = [("Subtile", 0.65), ("Normale", 1.0), ("Intense", 1.3)]

    private init() {
        style = DiscStyle(rawValue: d.string(forKey: "discStyle") ?? "") ?? .record
        showTonearm = d.object(forKey: "showTonearm") as? Bool ?? true
        desktopScale = d.object(forKey: "desktopScale") as? Double ?? 1.0
        spinSpeed = d.object(forKey: "spinSpeed") as? Double ?? 45
        waveIntensity = d.object(forKey: "waveIntensity") as? Double ?? 1.0
        desktopLyrics = d.object(forKey: "desktopLyrics") as? Bool ?? true
        hideInFullscreen = d.object(forKey: "hideInFullscreen") as? Bool ?? true
    }
}

final class WindowVisibility: ObservableObject {
    @Published var visible = true
    @Published var enabled = true
}

extension NSColor {
    func hueShifted(_ delta: CGFloat, brightness: CGFloat? = nil) -> NSColor {
        guard let c = usingColorSpace(.deviceRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var nh = (h + delta).truncatingRemainder(dividingBy: 1)
        if nh < 0 { nh += 1 }
        return NSColor(hue: nh, saturation: s, brightness: brightness ?? b, alpha: a)
    }

    var secondaryAccent: NSColor { hueShifted(0.09, brightness: 1) }
}

// MARK: - Horloge de la platine (rotation, bras et couleurs, avec inertie)

final class DeckClock {
    private(set) var spin: Double = 0  // degrés
    private(set) var arm: Double = 0   // radians
    private(set) var color1 = Color.green
    private(set) var color2 = Color.green
    private var velocity: Double = 0
    private var last: Date?
    private var rgb1: [Double]?
    private var rgb2: [Double]?

    func tick(_ date: Date, playing: Bool, speed: Double, armTarget: Double = 0, accent: NSColor) {
        let dt = last.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        last = date
        velocity += ((playing ? speed : 0) - velocity) * min(1, dt * 2.2)
        spin = (spin + velocity * dt).truncatingRemainder(dividingBy: 360)
        arm += (armTarget - arm) * min(1, dt * 2.4)

        // Transition douce des couleurs entre deux pochettes
        let k = rgb1 == nil ? 1 : min(1, dt * 2.5)
        rgb1 = Self.blend(rgb1, accent, k)
        rgb2 = Self.blend(rgb2, accent.secondaryAccent, k)
        color1 = Self.color(rgb1!)
        color2 = Self.color(rgb2!)
    }

    /// Le scratch fait tourner le disque à la main.
    func nudge(_ degrees: Double) {
        spin += degrees
        velocity = 0
    }

    private static func blend(_ current: [Double]?, _ target: NSColor, _ k: Double) -> [Double] {
        let c = target.usingColorSpace(.sRGB) ?? target
        let t = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
        guard let current, k < 1 else { return t }
        return zip(current, t).map { $0 + ($1 - $0) * k }
    }

    private static func color(_ v: [Double]) -> Color { Color(.sRGB, red: v[0], green: v[1], blue: v[2]) }
}

extension Color {
    /// Couleur arrondie : évite de redessiner le bras pour des variations invisibles pendant les transitions.
    var quantized: Color {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        func q(_ x: CGFloat) -> Double { (Double(x) * 32).rounded() / 32 }
        return Color(.sRGB, red: q(c.redComponent), green: q(c.greenComponent), blue: q(c.blueComponent))
    }
}

// MARK: - Le disque

/// Face tournante animée par Core Animation + décor fixe (reflets, axe, bord) dessiné par SwiftUI.
struct VinylDisc: View, Equatable {
    static func == (a: VinylDisc, b: VinylDisc) -> Bool {
        a.image === b.image && a.playing == b.playing && a.speed == b.speed && a.scratch == b.scratch
            && a.size == b.size && a.accent == b.accent && a.faceAccent == b.faceAccent
            && a.style == b.style && a.labelRatio == b.labelRatio
    }

    let image: NSImage?
    let playing: Bool
    let speed: Double
    var scratch: Double? = nil
    let size: CGFloat
    var accent: Color = .green
    var faceAccent: NSColor = .systemGreen
    var style: DiscStyle = .record
    var labelRatio: CGFloat = 0.40

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black)
                .shadow(color: .black.opacity(0.55), radius: size * 0.07, y: size * 0.035)
            SpinningImage(image: DiscFaceCache.image(artwork: image, size: size, accent: faceAccent,
                                                     style: style, labelRatio: labelRatio),
                          playing: playing, speed: speed, scratch: scratch)
                .frame(width: size, height: size)
            Group {
                switch style {
                case .record: recordOverlay
                case .picture: pictureOverlay
                }
                spindle
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.03), .white.opacity(0.2)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: max(1, size * 0.006))
            }
            .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
    }

    private var recordOverlay: some View {
        ZStack {
            sheen(strength: 1)
            Circle()
                .fill(AngularGradient(colors: [accent.opacity(0), accent.opacity(0.22), accent.opacity(0),
                                               accent.opacity(0.14), accent.opacity(0)],
                                      center: .center, angle: .degrees(25)))
                .blendMode(.plusLighter)
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.16), .clear],
                                     center: UnitPoint(x: 0.3, y: 0.25), startRadius: 0,
                                     endRadius: size * labelRatio * 0.6))
                .frame(width: size * labelRatio, height: size * labelRatio)
            Circle()
                .stroke(accent.opacity(0.55), lineWidth: max(0.8, size * 0.004))
                .frame(width: size * labelRatio + size * 0.025)
        }
    }

    private var pictureOverlay: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [.clear, .clear, .black.opacity(0.35)],
                                         center: .center, startRadius: 0, endRadius: size / 2))
            sheen(strength: 0.8)
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: max(0.8, size * 0.004))
                .frame(width: size * 0.30)
            Circle()
                .fill(Color.black.opacity(0.25))
                .frame(width: size * 0.30)
                .blendMode(.multiply)
        }
    }

    private func sheen(strength: Double) -> some View {
        Circle()
            .fill(AngularGradient(gradient: Gradient(stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0.22 * strength), location: 0.07),
                .init(color: .white.opacity(0), location: 0.17),
                .init(color: .white.opacity(0), location: 0.5),
                .init(color: .white.opacity(0.15 * strength), location: 0.57),
                .init(color: .white.opacity(0), location: 0.67),
                .init(color: .white.opacity(0), location: 1),
            ]), center: .center, angle: .degrees(-65)))
            .blendMode(.plusLighter)
    }

    private var spindle: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.6))
                .frame(width: size * 0.065)
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.97), Color(white: 0.6), Color(white: 0.28)],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.03))
                .frame(width: size * 0.045)
        }
    }
}

/// Sillons concentriques (statiques : un cercle reste un cercle en tournant).
struct Grooves: View, Equatable {
    let inner: CGFloat
    let dark: Bool

    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let R = sz.width / 2
            let rMax = R * 0.965
            let rMin = R * inner + 3
            let count = max(Int((rMax - rMin) / 1.5), 8)
            func ring(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }

            for i in 0..<count {
                let r = rMin + CGFloat(i) * (rMax - rMin) / CGFloat(count)
                let x = sin(Double(i) * 12.9898) * 43758.5453
                let n = x - x.rounded(.down)
                let color: Color = dark ? .black.opacity(0.07 + n * 0.12) : .white.opacity(0.018 + n * 0.05)
                ctx.stroke(ring(r), with: .color(color), lineWidth: 0.6)
            }
            for g in [0.22, 0.47, 0.70, 0.88] {
                let r = rMin + CGFloat(g) * (rMax - rMin)
                ctx.stroke(ring(r), with: .color(.black.opacity(dark ? 0.35 : 0.7)), lineWidth: max(1.5, R * 0.012))
                ctx.stroke(ring(r + 1), with: .color(.white.opacity(dark ? 0.1 : 0.07)), lineWidth: 0.6)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bras de lecture

struct Tonearm: View, Equatable {
    /// Géométrie de base (échelle 1), mise à l'échelle au dessin.
    let pivot: CGPoint
    let angle: Double // radians, 0 = au repos (vers le bas)
    let length: CGFloat
    let accent: Color
    var scale: CGFloat = 1

    static func tip(length: CGFloat) -> CGPoint { CGPoint(x: -length * 0.07, y: length) }

    /// Angle qui place la pointe à `radius` du centre du disque.
    static func angle(forRadius radius: CGFloat, pivot: CGPoint, center: CGPoint, length: CGFloat) -> Double {
        let t = tip(length: length)
        var best = 0.0, bestErr = CGFloat.greatestFiniteMagnitude
        for i in 0...400 {
            let a = Double(i) / 400 * 1.4
            let x = pivot.x + t.x * cos(a) - t.y * sin(a)
            let y = pivot.y + t.x * sin(a) + t.y * cos(a)
            let err = abs(hypot(x - center.x, y - center.y) - radius)
            if err < bestErr { bestErr = err; best = a }
        }
        return best
    }

    var body: some View {
        Canvas { ctx, _ in
            ctx.scaleBy(x: scale, y: scale)
            let metal = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(white: 0.95), Color(white: 0.55), Color(white: 0.85)]),
                startPoint: CGPoint(x: -4, y: 0), endPoint: CGPoint(x: 4, y: 0))

            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.55), radius: 7, x: 4, y: 7))

                let base = Path(ellipseIn: CGRect(x: pivot.x - 26, y: pivot.y - 26, width: 52, height: 52))
                layer.fill(base, with: .radialGradient(Gradient(colors: [Color(white: 0.32), Color(white: 0.12)]),
                                                       center: CGPoint(x: pivot.x - 8, y: pivot.y - 8),
                                                       startRadius: 0, endRadius: 34))
                layer.stroke(base, with: .color(.white.opacity(0.18)), lineWidth: 1)

                var arm = layer
                arm.translateBy(x: pivot.x, y: pivot.y)
                arm.rotate(by: .radians(angle))

                let weight = Path(roundedRect: CGRect(x: -12, y: -52, width: 24, height: 26), cornerRadius: 5)
                arm.fill(weight, with: .linearGradient(Gradient(colors: [Color(white: 0.75), Color(white: 0.35), Color(white: 0.6)]),
                                                       startPoint: CGPoint(x: -12, y: 0), endPoint: CGPoint(x: 12, y: 0)))
                arm.fill(Path(CGRect(x: -12, y: -36, width: 24, height: 2)), with: .color(accent.opacity(0.9)))

                let tip = Self.tip(length: length)
                var tube = Path()
                tube.move(to: CGPoint(x: 0, y: -24))
                tube.addLine(to: CGPoint(x: 0, y: length * 0.72))
                tube.addQuadCurve(to: CGPoint(x: tip.x, y: tip.y - 18), control: CGPoint(x: 0, y: length * 0.9))
                arm.stroke(tube, with: metal, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                arm.stroke(tube, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

                var head = arm
                head.translateBy(x: tip.x, y: tip.y - 8)
                head.rotate(by: .degrees(18))
                let shell = Path(roundedRect: CGRect(x: -9, y: -16, width: 18, height: 30), cornerRadius: 3)
                head.fill(shell, with: .linearGradient(Gradient(colors: [Color(white: 0.25), Color(white: 0.1)]),
                                                       startPoint: CGPoint(x: -9, y: 0), endPoint: CGPoint(x: 9, y: 0)))
                head.stroke(shell, with: .color(accent.opacity(0.8)), lineWidth: 1)
                head.fill(Path(roundedRect: CGRect(x: -5, y: 6, width: 10, height: 10), cornerRadius: 2), with: .color(accent))
                head.stroke(Path { p in p.move(to: CGPoint(x: 9, y: -6)); p.addLine(to: CGPoint(x: 20, y: -2)) },
                            with: .color(Color(white: 0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

                let cap = Path(ellipseIn: CGRect(x: pivot.x - 9, y: pivot.y - 9, width: 18, height: 18))
                layer.fill(cap, with: .radialGradient(Gradient(colors: [Color(white: 0.95), Color(white: 0.45)]),
                                                      center: CGPoint(x: pivot.x - 3, y: pivot.y - 3),
                                                      startRadius: 0, endRadius: 11))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - L'onde autour du disque

struct WaveRing: View {
    let bands: [Float]
    let level: Float
    let pulse: Double
    let color: Color
    let color2: Color
    let innerRadius: CGFloat
    let maxLength: CGFloat
    let rotation: Double // radians

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let values = bands + bands.reversed() // symétrique gauche/droite, graves en bas
            let n = values.count

            // Halo qui respire avec le volume et claque sur les kicks
            let glowR = innerRadius + 30 + CGFloat(level) * maxLength + CGFloat(pulse) * maxLength * 0.35
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
                     with: .radialGradient(Gradient(colors: [color.opacity(0.42 + pulse * 0.25), color2.opacity(0.12), color.opacity(0)]),
                                           center: c, startRadius: innerRadius * 0.9, endRadius: glowR))

            // Onde de choc sur chaque kick
            if pulse > 0.02 {
                let r = innerRadius + CGFloat(1 - pulse) * maxLength * 1.1
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(color.opacity(pulse * 0.6)), lineWidth: 2 + CGFloat(pulse) * 3)
            }

            for (i, v) in values.enumerated() where v > 0.04 {
                let a = rotation + Double(i) / Double(n) * 2 * .pi + .pi / 2
                let r0 = innerRadius + 5
                let r1 = innerRadius + 5 + CGFloat(v) * maxLength * 0.82
                var p = Path()
                p.move(to: CGPoint(x: c.x + r0 * CGFloat(cos(a)), y: c.y + r0 * CGFloat(sin(a))))
                p.addLine(to: CGPoint(x: c.x + r1 * CGFloat(cos(a)), y: c.y + r1 * CGFloat(sin(a))))
                ctx.stroke(p, with: .color(.white.opacity(0.10 + Double(v) * 0.25)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }

            let span = innerRadius + maxLength
            let dir = CGPoint(x: CGFloat(cos(rotation)) * span, y: CGFloat(sin(rotation)) * span)
            let conic = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [color, color2, color]),
                startPoint: CGPoint(x: c.x - dir.x, y: c.y - dir.y), endPoint: CGPoint(x: c.x + dir.x, y: c.y + dir.y))

            let outer = Self.smoothPath(center: c, values: values, base: innerRadius, scale: maxLength, rotation: rotation)
            ctx.fill(outer, with: .radialGradient(Gradient(colors: [color.opacity(0.5), color2.opacity(0.08)]),
                                                  center: c, startRadius: innerRadius, endRadius: innerRadius + maxLength))
            ctx.opacity = 0.22
            ctx.stroke(outer, with: conic, lineWidth: 7)
            ctx.opacity = 1
            ctx.stroke(outer, with: conic, lineWidth: 2)

            let echo = Self.smoothPath(center: c, values: values.map { $0 * 0.62 }, base: innerRadius, scale: maxLength,
                                       rotation: -rotation * 1.6 + .pi / Double(n))
            ctx.stroke(echo, with: .color(.white.opacity(0.55)), lineWidth: 1)

            for (i, v) in values.enumerated() where i % 3 == 0 && v > 0.35 {
                let a = rotation + Double(i) / Double(n) * 2 * .pi + .pi / 2
                let r = innerRadius + CGFloat(v) * maxLength + 9
                let p = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
                let d = 1.5 + CGFloat(v) * 2.5
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                         with: .color(.white.opacity(Double(v) * 0.85)))
            }
        }
        .drawingGroup() // rendu Metal (GPU) plutôt que CoreGraphics (CPU)
        .allowsHitTesting(false)
    }

    static func smoothPath(center c: CGPoint, values: [Float], base: CGFloat, scale: CGFloat, rotation: Double) -> Path {
        let n = values.count
        guard n > 2 else { return Path() }
        let pts: [CGPoint] = (0..<n).map { i in
            let a = rotation + Double(i) / Double(n) * 2 * .pi + .pi / 2
            let r = base + CGFloat(max(values[i], 0.025)) * scale
            return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var p = Path()
        p.move(to: mid(pts[n - 1], pts[0]))
        for i in 0..<n {
            p.addQuadCurve(to: mid(pts[i], pts[(i + 1) % n]), control: pts[i])
        }
        p.closeSubpath()
        return p
    }
}

func syntheticBands(at date: Date) -> [Float] {
    let t = Float(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))
    let n = AudioCapture.bandCount
    return (0..<n).map { i in
        let x = Float(i) / Float(n)
        let v = 0.35 + 0.22 * sin(t * 2.6 + x * 11) + 0.12 * sin(t * 6.1 - x * 23)
        return max(0, v * (1 - x * 0.45))
    }
}

// MARK: - Widget du bureau (centré, fixe)

struct DesktopWidgetView: View {
    @ObservedObject var spotify: SpotifyMonitor
    @ObservedObject var lyrics: LyricsProvider
    @ObservedObject var visibility: WindowVisibility
    @ObservedObject var settings = AppSettings.shared
    let audio: AudioCapture

    @State private var clock = DeckClock()

    // Géométrie de base (échelle 1)
    private static let baseDisc: CGFloat = 270
    private static let baseRing: CGFloat = 560
    private static let baseCenter = CGPoint(x: baseRing / 2, y: baseRing / 2)
    private static let basePivot = CGPoint(x: baseRing / 2 + 192, y: baseRing / 2 - 150)
    private static let armLength: CGFloat = 238
    private static let armStart = Tonearm.angle(forRadius: baseDisc / 2 * 0.92, pivot: basePivot, center: baseCenter, length: armLength)
    private static let armEnd = Tonearm.angle(forRadius: baseDisc / 2 * 0.40 + 10, pivot: basePivot, center: baseCenter, length: armLength)

    static func size(scale: Double) -> CGSize { CGSize(width: 580 * scale, height: 690 * scale) }
    /// Distance entre le haut de la fenêtre et le centre du disque.
    static func discCenterFromTop(scale: Double) -> CGFloat { baseRing / 2 * scale }

    var body: some View {
        let s = CGFloat(settings.desktopScale)
        let disc = Self.baseDisc * s
        let ring = Self.baseRing * s
        let size = Self.size(scale: settings.desktopScale)

        VStack(spacing: 4 * s) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !spotify.animating || !visibility.visible || !visibility.enabled)) { ctx in
                let snap = audio.snapshot()
                let swapping = ctx.date.timeIntervalSince(spotify.artworkChangedAt) < 1.1
                let armTarget = spotify.isPlaying && !swapping
                    ? Self.armStart + (Self.armEnd - Self.armStart) * spotify.progress(at: ctx.date) : 0
                let _ = clock.tick(ctx.date, playing: spotify.isPlaying, speed: settings.spinSpeed,
                                   armTarget: armTarget, accent: spotify.accent)
                let pulse = spotify.isPlaying ? snap.pulse(at: ctx.date) : 0
                let bands = spotify.isPlaying && !snap.hasSignal ? syntheticBands(at: ctx.date) : snap.bands

                ZStack {
                    WaveRing(bands: bands, level: spotify.isPlaying ? snap.level : 0, pulse: pulse,
                             color: clock.color1, color2: clock.color2,
                             innerRadius: disc / 2 + 4 * s,
                             maxLength: 92 * s * CGFloat(settings.waveIntensity),
                             rotation: clock.spin * .pi / 180 * 0.25)
                    ZStack {
                        VinylDisc(image: spotify.artwork, playing: spotify.isPlaying, speed: settings.spinSpeed,
                                  size: disc, accent: clock.color1.quantized, faceAccent: spotify.accent,
                                  style: settings.style)
                            .equatable()
                            .id(spotify.artworkVersion)
                            .transition(.asymmetric(
                                insertion: .offset(x: ring * 0.75).combined(with: .opacity),
                                removal: .offset(x: -ring * 0.75).combined(with: .opacity)))
                    }
                    .scaleEffect(1 + 0.022 * pulse)
                    .animation(.spring(response: 1.0, dampingFraction: 0.86), value: spotify.artworkVersion)
                    if settings.showTonearm {
                        Tonearm(pivot: Self.basePivot, angle: (clock.arm * 500).rounded() / 500,
                                length: Self.armLength, accent: clock.color1.quantized, scale: s)
                            .equatable()
                    }
                }
                .frame(width: ring, height: ring)
            }

            VStack(spacing: 4 * s) {
                Text(spotify.track == nil ? "EN ATTENTE" : (spotify.isPlaying ? "EN LECTURE" : "EN PAUSE"))
                    .font(.system(size: 10 * s, weight: .heavy, design: .rounded))
                    .tracking(3 * s)
                    .foregroundStyle(Color(nsColor: spotify.accent))
                Text(spotify.track?.name ?? "Rien en lecture")
                    .font(.system(size: 21 * s, weight: .bold, design: .rounded))
                Text(spotify.track.map { "\($0.artist)  ·  \($0.album)" } ?? "Lance une musique sur Spotify")
                    .font(.system(size: 13 * s, weight: .medium, design: .rounded))
                    .opacity(0.78)
                if settings.desktopLyrics, !lyrics.lines.isEmpty {
                    let line = lyrics.currentLine ?? "♪"
                    Text(line)
                        .font(.system(size: 15 * s, weight: .semibold, design: .serif))
                        .italic()
                        .id(line)
                        .transition(.opacity.combined(with: .offset(y: 6 * s)))
                        .animation(.easeOut(duration: 0.35), value: line)
                        .padding(.top, 6 * s)
                }
            }
            .lineLimit(1)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.75), radius: 6, y: 1)
            .frame(maxWidth: 480 * s)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}

// MARK: - Widget du coin (caché en bas à gauche)

enum CornerPanel { case queue, lyrics }

final class CornerState: ObservableObject {
    @Published var expanded = false
    @Published var visible = false
    @Published var panel: CornerPanel?
}

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct GlassBackground: View {
    let accent: Color
    let accent2: Color
    var radius: CGFloat = 28

    var body: some View {
        ZStack {
            VisualEffectBlur()
            LinearGradient(colors: [accent.opacity(0.38), accent2.opacity(0.10), Color.black.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }
}

/// Barre réglable (progression / volume).
struct ScrubBar: View {
    let value: Double
    let accent: Color
    var continuous = false
    let onChange: (_ value: Double, _ final: Bool) -> Void

    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let v = min(max(dragging ?? value, 0), 1)
            let h: CGFloat = dragging == nil ? 4 : 6
            let knob: CGFloat = dragging == nil ? 9 : 12
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15)).frame(height: h)
                Capsule()
                    .fill(LinearGradient(colors: [accent.opacity(0.75), accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(h, w * v), height: h)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: w * v - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = min(max(g.location.x / w, 0), 1)
                        dragging = f
                        if continuous { onChange(f, false) }
                    }
                    .onEnded { g in
                        onChange(min(max(g.location.x / w, 0), 1), true)
                        dragging = nil
                    }
            )
            .animation(.easeOut(duration: 0.12), value: dragging == nil)
        }
        .frame(height: 16)
    }
}

struct CornerWidgetView: View {
    @ObservedObject var spotify: SpotifyMonitor
    @ObservedObject var state: CornerState
    @ObservedObject var web: SpotifyWebAPI
    @ObservedObject var lyrics: LyricsProvider
    @ObservedObject var settings = AppSettings.shared
    let audio: AudioCapture

    private struct Scratch { var lastAngle: Double; var total: Double }

    @State private var clock = DeckClock()
    @State private var copied = false
    @State private var scratch: Scratch?

    static let size = CGSize(width: 480, height: 430)
    static let disc: CGFloat = 136
    static let margin: CGFloat = 16
    static let cardHeight: CGFloat = 176
    static let panelHeight: CGFloat = 186
    static let secondsPerTurn = 4.0
    // Coordonnées AppKit (origine en bas à gauche de la fenêtre)
    /// Replié : seul un petit quart du disque dépasse du coin (~25 px).
    static let collapsedCenter = CGPoint(x: -34, y: -34)
    static var expandedCenter: CGPoint { CGPoint(x: margin + disc / 2 + 4, y: margin + cardHeight / 2) }
    static var hiddenCenter: CGPoint { CGPoint(x: -disc, y: -disc) }
    static func hoverZoneHeight(panelOpen: Bool) -> CGFloat {
        margin + cardHeight + 8 + (panelOpen ? panelHeight + 10 : 0)
    }

    private var center: CGPoint {
        if !state.visible { return Self.hiddenCenter }
        return state.expanded ? Self.expandedCenter : Self.collapsedCenter
    }

    private var cardLeading: CGFloat { Self.expandedCenter.x }
    private var cardWidth: CGFloat { Self.size.width - 14 - cardLeading }

    var body: some View {
        let accent = Color(nsColor: spotify.accent)
        let accent2 = Color(nsColor: spotify.accent.secondaryAccent)
        let H = Self.size.height
        let side = Self.disc + 12
        ZStack(alignment: .topLeading) {
            // Panneau « À suivre » / « Paroles ». Les paroles restent épinglées quand la carte se referme.
            if state.visible, let panel = state.panel, state.expanded || panel == .lyrics {
                let r = Self.panelRect(expanded: state.expanded)
                extraPanel(panel, accent: accent, accent2: accent2)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: H - r.midY)
                    .transition(.opacity.combined(with: .offset(y: 20)))
            }

            // Halo + anneau de progression : SOUS la carte
            TimelineView(.animation(minimumInterval: 1 / 30,
                                    paused: !spotify.animating || !state.visible || !state.expanded)) { ctx in
                let snap = audio.snapshot()
                let _ = clock.tick(ctx.date, playing: spotify.isPlaying && scratch == nil,
                                   speed: settings.spinSpeed, accent: spotify.accent)
                let pulse = spotify.isPlaying && state.expanded ? snap.pulse(at: ctx.date) : 0
                ZStack {
                    if state.expanded {
                        Circle()
                            .fill(RadialGradient(colors: [clock.color1.opacity(0.6 + pulse * 0.3), clock.color1.opacity(0)],
                                                 center: .center, startRadius: Self.disc * 0.3, endRadius: Self.disc * 0.75))
                            .frame(width: Self.disc * 1.5, height: Self.disc * 1.5)
                            .scaleEffect(1 + pulse * 0.15)
                    }
                    Circle()
                        .stroke(Color.white.opacity(0.10), lineWidth: 3)
                        .frame(width: side, height: side)
                    Circle()
                        .trim(from: 0, to: spotify.progress(at: ctx.date))
                        .stroke(clock.color1, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: side, height: side)
                }
                .frame(width: side, height: side)
            }
            .allowsHitTesting(false)
            .position(x: center.x, y: H - center.y)

            if state.expanded {
                card(accent: accent, accent2: accent2)
                    .frame(width: cardWidth, height: Self.cardHeight)
                    .position(x: cardLeading + cardWidth / 2, y: H - Self.expandedCenter.y)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: -50)).combined(with: .scale(scale: 0.92, anchor: .leading)),
                        removal: .opacity.combined(with: .offset(x: -50))))
            }

            // Le disque, au-dessus (sa rotation est gérée par Core Animation)
            ZStack {
                ZStack {
                    VinylDisc(image: spotify.artwork, playing: spotify.isPlaying, speed: settings.spinSpeed,
                              scratch: scratch?.total, size: Self.disc,
                              accent: Color(nsColor: spotify.accent).quantized, faceAccent: spotify.accent,
                              style: settings.style, labelRatio: 0.52)
                        .equatable()
                        .id(spotify.artworkVersion)
                        .transition(.offset(x: -170, y: 170).combined(with: .opacity))
                }
                .animation(.spring(response: 0.8, dampingFraction: 0.85), value: spotify.artworkVersion)

                if let scratch {
                    Text(Self.signed(scratch.total / 360 * Self.secondsPerTurn))
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                }
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(scratchGesture(side: side))
            .position(x: center.x, y: H - center.y)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: state.expanded)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: state.visible)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.panel)
        .animation(.easeInOut(duration: 0.8), value: spotify.accent)
        .environment(\.colorScheme, .dark)
    }

    /// Cadre du panneau (coordonnées AppKit) : au-dessus de la carte quand elle est ouverte,
    /// sinon épinglé en bas à gauche, à côté du disque replié.
    static func panelRect(expanded: Bool) -> CGRect {
        if expanded {
            return CGRect(x: 14, y: margin + cardHeight + 10, width: size.width - 28, height: panelHeight)
        }
        return CGRect(x: 48, y: margin, width: 360, height: 156)
    }

    // MARK: Scratch : faire tourner le disque à la main pour avancer / reculer

    private func scratchGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let a = atan2(g.location.y - side / 2, g.location.x - side / 2) * 180 / .pi
                if var s = scratch {
                    var d = a - s.lastAngle
                    if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                    s.total += d
                    s.lastAngle = a
                    scratch = s
                } else if hypot(g.translation.width, g.translation.height) > 3 {
                    scratch = Scratch(lastAngle: a, total: 0)
                }
            }
            .onEnded { _ in
                if let s = scratch, abs(s.total) > 4, let track = spotify.track, track.duration > 0 {
                    let target = spotify.currentPosition() + s.total / 360 * Self.secondsPerTurn
                    spotify.seek(toFraction: target / track.duration)
                } else if scratch == nil {
                    spotify.playPause() // simple clic
                }
                scratch = nil
            }
    }

    // MARK: Carte principale

    @ViewBuilder
    private func card(accent: Color, accent2: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spotify.isPlaying ? "EN LECTURE" : "EN PAUSE")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(accent)
                    Text(spotify.track?.name ?? "")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(spotify.track?.artist ?? "")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if web.isConfigured {
                    pill(web.isLiked == true ? "heart.fill" : "heart",
                         help: web.isLoggedIn ? "J'aime" : "Connecter mon compte Spotify",
                         on: web.isLiked == true, accent: accent) { web.toggleLike() }
                }
            }

            TimelineView(.periodic(from: .distantPast, by: 0.5)) { ctx in
                VStack(spacing: 0) {
                    ScrubBar(value: spotify.progress(at: ctx.date), accent: accent) { f, final in
                        if final { spotify.seek(toFraction: f) }
                    }
                    HStack {
                        Text(Self.format(spotify.currentPosition(at: ctx.date)))
                        Spacer()
                        Text("-" + Self.format((spotify.track?.duration ?? 0) - spotify.currentPosition(at: ctx.date)))
                    }
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                }
            }

            HStack(spacing: 0) {
                toggle("shuffle", on: spotify.shuffling, accent: accent) { spotify.toggleShuffle() }
                Spacer()
                control("backward.fill", size: 15) { spotify.previous() }
                Spacer()
                Button(action: spotify.playPause) {
                    Image(systemName: spotify.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(.black)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.white))
                        .shadow(color: accent.opacity(0.6), radius: 8)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                control("forward.fill", size: 15) { spotify.next() }
                Spacer()
                toggle("repeat", on: spotify.repeating, accent: accent) { spotify.toggleRepeat() }
            }

            HStack(spacing: 6) {
                pill("music.note.list", help: "À suivre", on: state.panel == .queue, accent: accent) { open(.queue) }
                pill("quote.bubble", help: "Paroles", on: state.panel == .lyrics, accent: accent) { open(.lyrics) }
                Image(systemName: spotify.volume < 1 ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 4)
                ScrubBar(value: spotify.volume / 100, accent: accent2, continuous: true) { f, final in
                    spotify.setVolume(f * 100, final: final)
                }
                pill(copied ? "checkmark" : "link", help: "Copier le lien", on: copied, accent: accent) {
                    spotify.copyLink()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }
                pill("arrow.up.forward.app", help: "Ouvrir Spotify", accent: accent) { spotify.openSpotify() }
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, Self.disc / 2 + 18)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .background(GlassBackground(accent: accent, accent2: accent2))
    }

    private func open(_ panel: CornerPanel) {
        state.panel = state.panel == panel ? nil : panel
        if state.panel == .queue { web.fetchQueue() }
    }

    // MARK: Panneau « À suivre » / « Paroles »

    @ViewBuilder
    private func extraPanel(_ panel: CornerPanel, accent: Color, accent2: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(panel == .queue ? "À SUIVRE" : "PAROLES")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(accent)
                Spacer()
                Button { state.panel = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            switch panel {
            case .queue: queueView(accent: accent)
            case .lyrics: lyricsView(accent: accent)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlassBackground(accent: accent, accent2: accent2, radius: 24))
    }

    @ViewBuilder
    private func queueView(accent: Color) -> some View {
        if !web.isConfigured {
            placeholder("La connexion au compte Spotify n'est pas configurée.")
        } else if !web.isLoggedIn {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connecte ton compte Spotify pour voir la file d'attente et liker des titres.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                Button { web.login() } label: {
                    Text("Se connecter")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
            }
        } else if web.queue.isEmpty {
            placeholder("La file d'attente est vide.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(web.queue.prefix(4)) { item in
                    HStack(spacing: 10) {
                        AsyncImage(url: item.imageURL) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.1)
                        }
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text(item.artist).font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lyricsView(accent: Color) -> some View {
        if lyrics.loading {
            HStack { ProgressView().controlSize(.small); Text("Recherche des paroles…").font(.system(size: 12)) }
                .foregroundStyle(.white.opacity(0.6))
        } else if !lyrics.lines.isEmpty {
            let idx = lyrics.currentIndex ?? -1
            VStack(alignment: .leading, spacing: 7) {
                ForEach(max(idx - 1, 0)..<min(max(idx - 1, 0) + 5, lyrics.lines.count), id: \.self) { i in
                    let text = lyrics.lines[i].text.isEmpty ? "♪" : lyrics.lines[i].text
                    Text(text)
                        .font(.system(size: i == idx ? 16 : 13, weight: i == idx ? .bold : .medium, design: .rounded))
                        .foregroundStyle(i == idx ? Color.white : Color.white.opacity(i < idx ? 0.3 : 0.5))
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
            .animation(.easeInOut(duration: 0.35), value: idx)
        } else if let plain = lyrics.plain {
            ScrollView(showsIndicators: false) {
                Text(plain)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            placeholder("Pas de paroles trouvées pour ce titre.")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
    }

    // MARK: Petits composants

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ symbol: String, on: Bool, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(on ? accent : .white.opacity(0.55))
                Circle().fill(on ? accent : .clear).frame(width: 4, height: 4)
            }
            .frame(width: 28, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pill(_ symbol: String, help: String, on: Bool = false, accent: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(on ? accent : .white.opacity(0.8))
                .frame(width: 25, height: 25)
                .background(Circle().fill(Color.white.opacity(on ? 0.2 : 0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    static func format(_ s: Double) -> String {
        let t = Int(max(s, 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static func signed(_ s: Double) -> String {
        (s >= 0 ? "+" : "−") + String(format: "%.0f s", abs(s))
    }
}
