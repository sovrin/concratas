// Rewrap a video into an Apple-written .mov without re-encoding (passthrough).
// ffmpeg's mov lacks cslg/sample groups; the wallpaper's sample reader fails on pause ("VideoSampleReadingErrors Code=4").
// usage: swift remux.swift <input.mov> <output.mov>
import AVFoundation

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: swift remux.swift <input.mov> <output.mov>"); exit(1) }
let output = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: output)

let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let track = try await asset.loadTracks(withMediaType: .video)[0]
let reader = try AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
reader.add(out)

let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
let hint = try await track.load(.formatDescriptions).first
let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
input.mediaTimeScale = 240_000 // same as Apple's file
input.transform = try await track.load(.preferredTransform)
writer.add(input)

// The wallpaper slows down/pauses by dropping HEVC temporal layers and reads them from per-sample attachments
// (Apple's own files carry them; without them it fails with "VideoSampleReadingErrors Code=4" and the video vanishes).
// So: read temporal id + TSA/STSA type from each frame's NAL header and attach them like VideoToolbox does.
let hvcC = ((hint.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) } as? [String: Any])?["hvcC"] as? Data)!
let ptl: [CFString: Any] = [ // profile/tier/level as stored in hvcC
    kCMHEVCTemporalLevelInfoKey_ProfileSpace: Int(hvcC[1] >> 6),
    kCMHEVCTemporalLevelInfoKey_TierFlag: Int(hvcC[1] >> 5 & 1),
    kCMHEVCTemporalLevelInfoKey_ProfileIndex: Int(hvcC[1] & 0x1f),
    kCMHEVCTemporalLevelInfoKey_ProfileCompatibilityFlags: hvcC.subdata(in: 2..<6),
    kCMHEVCTemporalLevelInfoKey_ConstraintIndicatorFlags: hvcC.subdata(in: 6..<12),
    kCMHEVCTemporalLevelInfoKey_LevelIndex: Int(hvcC[12]),
]
let lengthSize = Int(hvcC[21] & 3) + 1
var layers = [Int: Int]()

// Re-time every frame to exact 1/240 s steps. Muxing x265's deep B-pyramid through ffmpeg leaves uneven or guessed
// timestamps, but their order is right: PTS = rank in display order, DTS = decode index minus the reorder depth.
let scan = try AVAssetReader(asset: asset), scanOut = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
scanOut.alwaysCopiesSampleData = false; scan.add(scanOut); scan.startReading()
var decodePTS = [Double]()
while let s = scanOut.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(s) > 0 { decodePTS.append(CMSampleBufferGetPresentationTimeStamp(s).seconds) } }
let rank = Dictionary(uniqueKeysWithValues: decodePTS.sorted().enumerated().map { ($1, $0) })
guard rank.count == decodePTS.count else { print("duplicate timestamps, cannot re-time"); exit(1) }
let reorder = decodePTS.enumerated().map { $0.offset - rank[$0.element]! }.max()!
let frame = CMTime(value: 1000, timescale: 240_000)
var n = 0

reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: .zero)
while let original = out.copyNextSampleBuffer() {
    guard CMSampleBufferGetNumSamples(original) > 0 else { continue }
    var timing = CMSampleTimingInfo(duration: frame,
                                    presentationTimeStamp: CMTimeMultiply(frame, multiplier: Int32(rank[CMSampleBufferGetPresentationTimeStamp(original).seconds]!)),
                                    decodeTimeStamp: CMTimeMultiply(frame, multiplier: Int32(n - reorder)))
    var copy: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: original, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
    let sample = copy!; n += 1
    if let block = CMSampleBufferGetDataBuffer(sample), let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        var i = 0
        while i + lengthSize + 2 <= bytes.count { // first VCL NAL (type < 32) decides the frame
            let len = bytes[i..<i + lengthSize].reduce(0) { $0 << 8 | Int($1) }
            let type = Int(bytes[i + lengthSize] >> 1 & 0x3f), tid = Int(bytes[i + lengthSize + 1] & 7) - 1
            if type < 32 {
                let d = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
                func set(_ k: CFString, _ v: Any) { CFDictionarySetValue(d, Unmanaged.passUnretained(k).toOpaque(), Unmanaged.passUnretained(v as AnyObject).toOpaque()) }
                var info = ptl; info[kCMHEVCTemporalLevelInfoKey_TemporalLevel] = tid
                set(kCMSampleAttachmentKey_HEVCTemporalLevelInfo, info as CFDictionary)
                if type == 2 || type == 3 { set(kCMSampleAttachmentKey_HEVCTemporalSubLayerAccess, kCFBooleanTrue!) }
                if type == 4 || type == 5 { set(kCMSampleAttachmentKey_HEVCStepwiseTemporalSubLayerAccess, kCFBooleanTrue!) }
                layers[tid, default: 0] += 1
                break
            }
            i += lengthSize + len
        }
    }
    while !input.isReadyForMoreMediaData { usleep(1000) }
    guard input.append(sample) else { print("append failed: \(String(describing: writer.error))"); exit(1) }
}
guard reader.status == .completed else { print("read failed: \(String(describing: reader.error))"); exit(1) }
input.markAsFinished()
await writer.finishWriting()
guard writer.status == .completed else { print("write failed: \(String(describing: writer.error))"); exit(1) }
print("wrote \(output.path)  reorder depth \(reorder)  frames per temporal layer: \(layers.sorted { $0.key < $1.key })")
