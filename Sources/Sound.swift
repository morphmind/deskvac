import AppKit
import AVFoundation
import QuickLookThumbnailing

/// Synthesized vacuum motor: brown-noise rumble plus a low hum, louder while driving,
/// with a short whoosh on every pickup. No audio files needed.
final class SynthState: @unchecked Sendable {
    var motorTarget: Float = 0
    var motor: Float = 0
    var master: Float = 0
    var masterTarget: Float = 0
    var whoosh: Float = 0
    private var brown: Float = 0
    private var hiss: Float = 0
    private var phase: Float = 0
    private var seed: UInt32 = 0x9E37_79B9

    private func noise() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Float(seed) / Float(UInt32.max) * 2 - 1
    }

    func next(sampleRate sr: Float) -> Float {
        motor += (motorTarget - motor) * 0.00025
        master += (masterTarget - master) * 0.0003
        whoosh *= 0.99985
        let w = noise()
        brown = (brown + 0.02 * w) / 1.02
        hiss += (w - hiss) * (0.05 + motor * 0.08)
        phase += 2 * .pi * (104 + motor * 26) / sr
        if phase > 2 * .pi { phase -= 2 * .pi }
        let hum = sin(phase) * 0.07 + sin(phase * 2) * 0.035 + sin(phase * 3) * 0.015
        let level = 0.3 + motor * 0.7
        let body = brown * 2.4 * level + hiss * 0.16 * level + hum * level
        return (body + hiss * whoosh * 0.9) * master * 0.55
    }
}

@MainActor
final class SoundEngine {
    static let shared = SoundEngine()
    private var engine: AVAudioEngine?
    private let state = SynthState()
    private var enabled = false

    func start(volume: Double, enabled on: Bool) {
        enabled = on
        guard on, engine == nil else { return }
        let e = AVAudioEngine()
        let rate = e.outputNode.outputFormat(forBus: 0).sampleRate
        let sr = Float(rate > 0 ? rate : 48000)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 1) else { return }
        let st = state
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            for frame in 0..<Int(frameCount) {
                let v = st.next(sampleRate: sr)
                for b in buffers { b.mData?.assumingMemoryBound(to: Float.self)[frame] = v }
            }
            return noErr
        }
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: format)
        e.mainMixerNode.outputVolume = Float(volume)
        state.masterTarget = 1
        do { try e.start(); engine = e } catch { enabled = false }
    }

    func stop() {
        state.masterTarget = 0
        state.motorTarget = 0
        let e = engine
        engine = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { e?.stop() }
    }

    func setMotor(_ level: Float) { state.motorTarget = level }
    func whoosh() { state.whoosh = 1 }

    func bump() {
        guard enabled else { return }
        NSSound(named: "Tink")?.play()
    }

    func chime() {
        guard enabled else { return }
        NSSound(named: "Glass")?.play()
    }
}

/// Finder-like thumbnails: real previews for images and PDFs, file type icons for the rest.
enum Thumbnails {
    static func load(_ items: [DeskItem], size: Double) async -> [UUID: NSImage] {
        var out: [UUID: NSImage] = [:]
        await withTaskGroup(of: (UUID, NSImage).self) { group in
            for item in items {
                let url = item.url, id = item.id
                group.addTask {
                    let req = QLThumbnailGenerator.Request(
                        fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .all
                    )
                    if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                        return (id, rep.nsImage)
                    }
                    return (id, NSWorkspace.shared.icon(forFile: url.path))
                }
            }
            for await (id, image) in group { out[id] = image }
        }
        return out
    }
}

enum MenuIcon {
    /// Same glyph as the app icon: solid shell, bumper seam and lidar cut out of it.
    static func make(running: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: 9.4, y: 8.6), r = 7.2
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(1.3)
            ctx.setLineCap(.round)
            ctx.addArc(center: c, radius: r * 0.7, startAngle: .pi * (-135 - 60) / 180, endAngle: .pi * (-135 + 60) / 180, clockwise: false)
            ctx.strokePath()
            let tr = r * 0.26
            let tc = CGPoint(x: c.x + r * 0.24, y: c.y - r * 0.24)
            ctx.fillEllipse(in: CGRect(x: tc.x - tr, y: tc.y - tr, width: tr * 2, height: tr * 2))
            ctx.setBlendMode(.normal)
            if running {
                ctx.fillEllipse(in: CGRect(x: 0.5, y: 12.5, width: 5, height: 5))
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
