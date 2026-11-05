// tacet-recorder: microphone capture for eval/record.py, done the way tacet's
// own Recorder (swift/Sources/tacet/Recorder.swift) does it, so a recorded eval
// clip is the audio tacet would have sent: AVAudioEngine's default input, a tap
// with a 4096-frame buffer, AVAudioConverter to 16 kHz mono 16-bit, and the
// canonical 44-byte WAV header.
//
// Built by record.py with `swiftc -O`. It speaks a line protocol:
//   stdin:  start | stop PATH | quit
//   stdout: ready DEVICE-NAME (at launch) | denied | started
//           | saved FRAMES RMS PEAK | error MESSAGE
// `tacet-recorder --selftest PATH` writes one second of a 440 Hz tone through
// the same WAV writer and exits, without touching the microphone.

import AVFoundation
import Foundation

struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

final class Capture {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "tacet.eval.recorder")
    private var samples = [Int16]()
    private var peak: Int32 = 0
    private var started = false

    func start() throws {
        queue.sync {
            samples.removeAll(keepingCapacity: true)
            peak = 0
        }
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw Failure("default input reports no usable stream (\(inFormat.channelCount) ch, \(inFormat.sampleRate) Hz)")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw Failure("no converter from \(inFormat) to 16 kHz mono 16-bit")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter, target: target)
        }
        engine.prepare()
        try engine.start()
        started = true
    }

    func stop() -> (samples: [Int16], peak: Int32) {
        guard started else { return ([], 0) }
        started = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return queue.sync { (samples, peak) }
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                         target: AVAudioFormat) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var provided = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let channel = out.int16ChannelData else { return }
        queue.sync {
            for i in 0..<Int(out.frameLength) {
                let s = channel[0][i]
                samples.append(s)
                peak = max(peak, abs(Int32(s)))
            }
        }
    }
}

func wavData(_ samples: [Int16]) -> Data {
    let dataBytes = samples.count * 2
    var out = Data(capacity: 44 + dataBytes)
    func ascii(_ s: String) { out.append(Data(s.utf8)) }
    func le16(_ v: Int) { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }
    func le32(_ v: Int) { le16(v & 0xFFFF); le16((v >> 16) & 0xFFFF) }
    ascii("RIFF"); le32(36 + dataBytes); ascii("WAVE")
    ascii("fmt "); le32(16); le16(1); le16(1); le32(16000); le32(32000); le16(2); le16(16)
    ascii("data"); le32(dataBytes)
    samples.withUnsafeBytes { out.append(contentsOf: $0) } // little endian on arm64 and x86
    return out
}

func save(_ samples: [Int16], peak: Int32, to path: String) throws -> String {
    try wavData(samples).write(to: URL(fileURLWithPath: path), options: .atomic)
    let sumSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    let rms = samples.isEmpty ? 0 : (sumSquares / Double(samples.count)).squareRoot()
    return "saved \(samples.count) \(String(format: "%.1f", rms)) \(peak)"
}

func microphoneAllowed() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined:
        let done = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { granted = $0; done.signal() }
        done.wait()
        return granted
    default: return false
    }
}

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

func serve() -> Int32 {
    guard microphoneAllowed() else { say("denied"); return 3 }
    say("ready \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown input")")
    let capture = Capture()
    while let line = readLine() {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        do {
            switch parts.first {
            case "start": try capture.start(); say("started")
            case "stop" where parts.count == 2:
                let (samples, peak) = capture.stop()
                say(try save(samples, peak: peak, to: parts[1]))
            case "quit": _ = capture.stop(); return 0
            default: say("error unknown command: \(line)")
            }
        } catch let failure as Failure {
            say("error \(failure.message)")
        } catch {
            say("error \(error)")
        }
    }
    _ = capture.stop()
    return 0
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--selftest" {
    let tone = (0..<16000).map { Int16(8000 * sin(2 * Double.pi * 440 * Double($0) / 16000)) }
    say((try? save(tone, peak: 8000, to: arguments[2])) ?? "error could not write \(arguments[2])")
    exit(0)
}
exit(serve())
