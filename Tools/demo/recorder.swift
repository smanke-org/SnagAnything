// Records only one app's windows on the built-in display, cropped, until the app exits.
// usage: recorder <pid> <x> <y> <w> <h> <out.mov>
// Prints "first <host seconds>" for the first frame, so the mix can line sound up with it.
import AVFoundation
import CoreMedia
import ScreenCaptureKit

let a = CommandLine.arguments
let pid = pid_t(a[1])!
let rect = CGRect(x: Double(a[2])!, y: Double(a[3])!, width: Double(a[4])!, height: Double(a[5])!)
let out = URL(fileURLWithPath: a[6])
try? FileManager.default.removeItem(at: out)

final class Sink: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AVAssetWriter, input: AVAssetWriterInput
    var started = false, frames = 0
    init(_ w: Int, _ h: Int) throws {
        writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 60_000_000, AVVideoExpectedSourceFrameRateKey: 60]])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
    }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = att[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startSession(atSourceTime: sb.presentationTimeStamp); started = true
            print("first \(CMTimeGetSeconds(sb.presentationTimeStamp))"); fflush(stdout)
        }
        if input.isReadyForMoreMediaData { input.append(sb); frames += 1 }
    }
}

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
      let app = content.applications.first(where: { $0.processID == pid }) else { print("no display/app"); exit(1) }
let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
let cfg = SCStreamConfiguration()
let scale = 2.0
cfg.sourceRect = rect
cfg.width = Int(rect.width * scale); cfg.height = Int(rect.height * scale)
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
cfg.showsCursor = false
cfg.pixelFormat = kCVPixelFormatType_32BGRA
cfg.queueDepth = 8
cfg.backgroundColor = .black
let sink = try Sink(cfg.width, cfg.height)
let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rec"))
try await stream.startCapture()
print("recording \(cfg.width)x\(cfg.height)"); fflush(stdout)
while kill(pid, 0) == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
try await stream.stopCapture()
sink.input.markAsFinished()
await sink.writer.finishWriting()
print("done frames=\(sink.frames) status=\(sink.writer.status.rawValue) \(sink.writer.error?.localizedDescription ?? "")")
