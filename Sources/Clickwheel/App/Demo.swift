import AVFoundation
import AppKit
import SwiftUI

/// Renders a scripted tour of the device to an H.264 movie and exits.
///
///     CLICKWHEEL_DEMO=/tmp/demo.mov open -W build/Clickwheel.app
///
/// The tour drives the real `Navigator`/`Player` through the same calls the
/// wheel makes, captures frames with `ImageRenderer` — the snapshot pipeline —
/// and writes them straight to the asset writer. No screen recording, no
/// permissions, and the lighting is animated the way the cursor animates it
/// live.
@MainActor
enum Demo {
    static var requestedPath: String? {
        ProcessInfo.processInfo.environment["CLICKWHEEL_DEMO"]
    }

    private static let fps = 30
    private static let size = CGSize(width: 1280, height: 720)   // points; ×2 scale
    private static let deviceHeight: CGFloat = 660

    // MARK: - The scene

    /// The device on a quiet dark ground, centred, like the stills.
    private struct Stage: View {
        let sheen: CGFloat
        let light: CGPoint

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.082, green: 0.090, blue: 0.106),
                        Color(red: 0.043, green: 0.047, blue: 0.055),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                IPodBody(height: Demo.deviceHeight, sheen: sheen, light: light)
            }
            .frame(width: Demo.size.width, height: Demo.size.height)
        }
    }

    // MARK: - Recording

    static func run(path: String, services: AppDelegate.Services) async {
        await services.library.start()
        await services.player.syncVolume()
        services.device.stageBatteryForPreview(0.8)
        if let favourites = services.library.favourites {
            _ = await services.library.songs(in: favourites)
        }

        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            FileHandle.standardError.write(Data("demo: cannot create writer\n".utf8))
            exit(1)
        }

        let pixelWidth = Int(size.width * 2), pixelHeight = Int(size.height * 2)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: pixelWidth,
                kCVPixelBufferHeightKey as String: pixelHeight,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let steps = script(services)
        var totalFrames = steps.map(\.frame).max().map { max($0 + 1, fps * 30) } ?? fps * 30
        // Short renders for iterating on the script.
        if let cap = ProcessInfo.processInfo.environment["CLICKWHEEL_DEMO_FRAMES"].flatMap({ Int($0) }) {
            totalFrames = min(totalFrames, max(1, cap))
        }
        print("demo: battery=\(services.device.batteryLevel) charging=\(services.device.isCharging)")
        var nextStep = 0

        for frame in 0..<totalFrames {
            // Fire every scripted action due this frame.
            while nextStep < steps.count, steps[nextStep].frame <= frame {
                steps[nextStep].action()
                nextStep += 1
            }

            // The room drifts the way the cursor drives it live.
            let t = Double(frame) / Double(fps)
            let sheen = 0.40 + 0.26 * sin(t * 0.50) + 0.08 * sin(t * 1.31)
            let light = CGPoint(
                x: 0.10 + 0.28 * sin(t * 0.42 + 0.8),
                y: -0.05 + 0.16 * sin(t * 0.33)
            )

            let renderer = ImageRenderer(
                content: Stage(sheen: sheen, light: light)
                    .environment(services.device)
                    .environment(services.library)
                    .environment(services.player)
                    .environment(services.navigator)
                    .environment(services.brick)
            )
            renderer.scale = 2
            renderer.isOpaque = true
            renderer.colorMode = .nonLinear

            guard let image = renderer.cgImage else { continue }
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard let buffer = pixelBuffer(from: image, adaptor: adaptor,
                                           width: pixelWidth, height: pixelHeight)
            else { continue }
            adaptor.append(buffer, withPresentationTime:
                CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))

            // Keep roughly real time so the song underneath genuinely plays
            // and the progress bar moves like the real thing.
            try? await Task.sleep(for: .milliseconds(18))
        }

        input.markAsFinished()
        await writer.finishWriting()
        await services.player.relinquish()
        print("demo: wrote \(path) (\(totalFrames) frames at \(fps) fps)")
        exit(0)
    }

    // MARK: - The tour

    private struct Step {
        let frame: Int
        let action: () -> Void
    }

    /// Thirty seconds: boot, browse, play, volume, scrub, hold, sleep, wake.
    private static func script(_ services: AppDelegate.Services) -> [Step] {
        let navigator = services.navigator
        let player = services.player
        let device = services.device
        var steps: [Step] = []

        func at(_ seconds: Double, _ action: @escaping () -> Void) {
            steps.append(Step(frame: Int(seconds * Double(fps)), action: action))
        }
        /// A run of wheel detents, one per frame gap.
        func scroll(from seconds: Double, by amounts: [Int], every gap: Double = 0.22) {
            for (offset, amount) in amounts.enumerated() {
                at(seconds + Double(offset) * gap) { navigator.scroll(by: amount) }
            }
        }

        // Boot, then the main menu.
        at(2.2) { navigator.finishBoot() }
        scroll(from: 3.2, by: [1, 1, 1, -1, -1, -1])

        // Music › browse the Artists list, then play from Songs so the
        // counter reads against the whole starred pool.
        at(5.2) { navigator.pressSelect() }                 // Music
        scroll(from: 5.8, by: [1])                          // → Artists
        at(6.4) { navigator.pressSelect() }
        scroll(from: 7.0, by: [1, 1, 1], every: 0.35)       // browse artists
        at(8.6) { navigator.pressMenu() }                   // back to Music
        scroll(from: 9.0, by: [1, 1], every: 0.3)           // → Songs
        at(9.9) { navigator.pressSelect() }
        scroll(from: 10.3, by: [1, 1], every: 0.3)          // third song
        at(11.2) { navigator.pressSelect() }                // play → Now Playing

        // Volume on the wheel, like the hardware.
        scroll(from: 13.4, by: [1, 1, 1, 1, 1, 1], every: 0.18)
        scroll(from: 15.0, by: [-1, -1, -1], every: 0.18)

        // Select arms the scrubber; seek ahead.
        at(16.6) { navigator.pressSelect() }
        scroll(from: 17.2, by: [1, 1, 1, 1, 1, 1, 1, 1], every: 0.16)
        at(19.2) { navigator.wheelIdled() }

        // Hold: everything dies, the padlock appears.
        at(20.5) { device.isHeld = true }
        at(22.5) { device.isHeld = false }

        // The backlight sleeps — transflective grey, not black — and wakes.
        at(24.0) { device.dimForPreview() }
        at(26.5) { device.wake() }

        // Back out to the main menu and rest there.
        at(27.5) { navigator.pressMenu() }
        at(28.1) { navigator.pressMenu() }
        at(28.7) { navigator.pressMenu() }
        _ = player
        return steps
    }

    // MARK: - Pixels

    private static func pixelBuffer(
        from image: CGImage,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
