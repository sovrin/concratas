// Hue-rotate the Tahoe wallpaper (video or still).
// usage: swift recolor.swift <degrees | #rrggbb> <input.mov|.heic> <output.mov|.heic> [pivot]
//   degrees: rotate all hues
//   #rrggbb: gradient-map brightness (luma only) black -> color -> white; pivot = source luma that becomes exactly the color (default 0.5, lower = brighter)
import AVFoundation
import CoreImage
import VideoToolbox

let args = CommandLine.arguments
let hexArg = args.count >= 4 && args[1].hasPrefix("#") ? Int(args[1].dropFirst(), radix: 16) : nil
let pivot = args.count == 5 ? Double(args[4]) : 0.5
guard args.count == 4 || args.count == 5, hexArg != nil || Double(args[1]) != nil, let pivot, pivot > 0, pivot < 1 else {
    // stderr: with output "-" stdout is the video pipe
    FileHandle.standardError.write("usage: swift recolor.swift <degrees | #rrggbb> <input> <output> [pivot 0..1]\n".data(using: .utf8)!); exit(1)
}
let input = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
// The output is deleted before the input is read; compare file identity so symlinks and case differences count as the same file.
let fileID = { (u: URL) in (try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject }
if let id = fileID(input), id == fileID(output) { print("output is the same file as the input, refusing to overwrite it"); exit(1) }
let angle = (Double(args[1]) ?? 0) * .pi / 180

// CIHueAdjust pushes 66-97% of this very saturated blue out of gamut; the clipping shows up as jagged contours.
// Instead: rotate hue in OKLCH and, if out of gamut, lower chroma until it fits. Baked into a 3D LUT.
func toLin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func toGamma(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
func oklab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
}
func linRGB(_ L: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
    let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
    return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
}
func inGamut(_ c: (Double, Double, Double)) -> Bool { [c.0, c.1, c.2].allSatisfy { $0 >= -1e-6 && $0 <= 1 + 1e-6 } }

let target = hexArg.map { v in oklab(toLin(Double(v >> 16 & 255) / 255), toLin(Double(v >> 8 & 255) / 255), toLin(Double(v & 255) / 255)) }

let cubeSize = 64
let cube: Data = {
    var d = [Float](); d.reserveCapacity(cubeSize * cubeSize * cubeSize * 4)
    for bi in 0..<cubeSize { for gi in 0..<cubeSize { for ri in 0..<cubeSize {
        let n = Double(cubeSize - 1)
        let (r, g, bl) = (Double(ri) / n, Double(gi) / n, Double(bi) / n)
        var (L, a, b) = oklab(toLin(r), toLin(g), toLin(bl))
        if let t = target {
            // Luma only: the source's chroma planes are quarter-res and heavily compressed; their block errors become "fractals" once recolored.
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl, Lt = t.0, at = t.1, bt = t.2
            let k = y < pivot ? y / pivot : 1 - (y - pivot) / (1 - pivot) // chroma weight: 0 at black/white, 1 at pivot
            L = y < pivot ? Lt * y / pivot : Lt + (1 - Lt) * (y - pivot) / (1 - pivot)
            a = at * k; b = bt * k
        }
        let C = hypot(a, b), h = target == nil ? atan2(b, a) + angle : atan2(b, a)
        var lo = 0.0, hi = C // largest chroma <= C that stays in gamut
        if !inGamut(linRGB(L, C * cos(h), C * sin(h))) {
            for _ in 0..<20 { let mid = (lo + hi) / 2; if inGamut(linRGB(L, mid * cos(h), mid * sin(h))) { lo = mid } else { hi = mid } }
        } else { lo = C }
        let c = linRGB(L, lo * cos(h), lo * sin(h))
        d += [c.0, c.1, c.2].map { Float(toGamma(min(max($0, 0), 1))) } + [1]
    }}}
    return d.withUnsafeBufferPointer { Data(buffer: $0) }
}()
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func hue(_ image: CIImage) -> CIImage {
    image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
        "inputCubeDimension": cubeSize, "inputCubeData": cube, "inputColorSpace": srgb,
    ])
}

try? FileManager.default.removeItem(at: output)

if input.pathExtension.lowercased() == "mov" {
    // Reader/writer instead of AVVideoComposition: the CI composition path runs through 8-bit BGRA and bands the gradients.
    let tenBit = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    let asset = AVURLAsset(url: input)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let size = try await track.load(.naturalSize)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: tenBit])
    reader.add(out)

    if args[3] == "-" {
        // Raw yuv420p10le frames to stdout, for a better encoder than VideoToolbox, whose flat 8px tiles show as steps in these gradients:
        // recolor ... - | ffmpeg -f rawvideo -pix_fmt yuv420p10le -s WxH -r 240 -i - -c:v libx265 ...
        let ctx = CIContext(options: [.workingFormat: CIFormat.RGBAh])
        var dst: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), tenBit, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &dst)
        let stdout = FileHandle.standardOutput
        reader.startReading()
        var done = false
        while !done {
            autoreleasepool {
                guard let sample = out.copyNextSampleBuffer() else { done = true; return }
                guard let src = CMSampleBufferGetImageBuffer(sample) else { return }
                CVBufferPropagateAttachments(src, dst!) // without the 709 tags CI encodes with a different transfer curve
                ctx.render(hue(CIImage(cvPixelBuffer: src)), to: dst!)
                CVPixelBufferLockBaseAddress(dst!, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(dst!, .readOnly) }
                // biplanar stores 10-bit in the high bits with interleaved CbCr; planar 10le wants low bits and separate U, V
                for plane in 0..<2 {
                    let w = CVPixelBufferGetWidthOfPlane(dst!, plane), h = CVPixelBufferGetHeightOfPlane(dst!, plane)
                    let rb = CVPixelBufferGetBytesPerRowOfPlane(dst!, plane) / 2
                    let p = CVPixelBufferGetBaseAddressOfPlane(dst!, plane)!.assumingMemoryBound(to: UInt16.self)
                    if plane == 0 {
                        var y = [UInt16](repeating: 0, count: w * h)
                        for r in 0..<h { for c in 0..<w { y[r * w + c] = p[r * rb + c] >> 6 } }
                        stdout.write(y.withUnsafeBufferPointer { Data(buffer: $0) })
                    } else {
                        var u = [UInt16](repeating: 0, count: w * h), v = u
                        for r in 0..<h { for c in 0..<w { u[r * w + c] = p[r * rb + 2 * c] >> 6; v[r * w + c] = p[r * rb + 2 * c + 1] >> 6 } }
                        stdout.write(u.withUnsafeBufferPointer { Data(buffer: $0) })
                        stdout.write(v.withUnsafeBufferPointer { Data(buffer: $0) })
                    }
                }
            }
        }
        guard reader.status == .completed else { FileHandle.standardError.write("read failed\n".data(using: .utf8)!); exit(1) }
        exit(0)
    }

    let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
    let color: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        AVVideoColorPropertiesKey: color,
        AVVideoCompressionPropertiesKey: [
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
            AVVideoAverageBitRateKey: 40_000_000, // original is ~6 Mbps; recolor exposes its artifacts, so give the re-encode lots of headroom
            // Apple's file: 240 fps, 13 keyframes in 60 s. VT's default (~1 per 28 frames) makes grain "boil" on every keyframe.
            AVVideoMaxKeyFrameIntervalKey: 1200,
            AVVideoMaxKeyFrameIntervalDurationKey: 5,
            AVVideoAllowFrameReorderingKey: true,
            AVVideoExpectedSourceFrameRateKey: 240,
        ],
    ])
    writerInput.transform = try await track.load(.preferredTransform)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: tenBit,
        kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ])
    writer.add(writerInput)

    // Float working space so the hue math itself doesn't quantize.
    let ctx = CIContext(options: [.workingFormat: CIFormat.RGBAh])
    reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    var done = false
    while !done {
        autoreleasepool { // without it CI intermediates pile up per frame until OOM
            guard let sample = out.copyNextSampleBuffer() else { done = true; return }
            guard let src = CMSampleBufferGetImageBuffer(sample) else { return }
            while !writerInput.isReadyForMoreMediaData { usleep(1000) }
            var dst: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &dst)
            CVBufferPropagateAttachments(src, dst!)
            ctx.render(hue(CIImage(cvPixelBuffer: src)), to: dst!)
            adaptor.append(dst!, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sample))
        }
    }
    guard reader.status == .completed else { print("read failed: \(String(describing: reader.error))"); exit(1) }
    writerInput.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { print("write failed: \(String(describing: writer.error))"); exit(1) }
} else {
    guard let src = CIImage(contentsOf: input, options: [.applyOrientationProperty: true]) else {
        print("cannot read \(input.path)"); exit(1)
    }
    let ctx = CIContext()
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    try ctx.writeHEIFRepresentation(of: hue(src), to: output, format: .RGBA8, colorSpace: p3)
}
print("wrote \(output.path)")
