import XCTest
import AVFoundation
@testable import MeetingCore

final class AudioTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingScribe-AudioTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String, rate: Double = 16_000, channels: [[Float]]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels.count)))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, channels[0].count))))
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
        for channel in channels.indices {
            for frame in channels[channel].indices { buffer.floatChannelData![channel][frame] = channels[channel][frame] }
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        if buffer.frameLength > 0 { try file.write(from: buffer) }
        return url
    }

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192))
        var result: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8_192, file.length - file.framePosition)))
            guard buffer.frameLength > 0 else { XCTFail("Unexpected empty read before EOF"); break }
            result.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return result
    }

    func testNormalizationResamplesDownmixesAndWritesPCM16WAV() async throws {
        let source = try fixture("stereo.caf", rate: 48_000, channels: [Array(repeating: 0.75, count: 48_000), Array(repeating: 0.25, count: 48_000)])
        let destination = directory.appendingPathComponent("asr.wav")
        let duration = try await AudioFileTools.prepareForASR(source: source, destination: destination)
        let output = try AVAudioFile(forReading: destination)
        XCTAssertEqual(duration, 1, accuracy: 0.0001)
        XCTAssertEqual(output.length, 16_000)
        XCTAssertEqual(output.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(output.fileFormat.channelCount, 1)
        XCTAssertEqual(output.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        XCTAssertEqual(try samples(destination)[8_000], 0.5, accuracy: 0.001)
        XCTAssertEqual(try AudioFileTools.duration(of: source), 1, accuracy: 0.0001)
        XCTAssertEqual(String(data: try Data(contentsOf: destination).prefix(4), encoding: .ascii), "RIFF")
    }

    func testNormalizationPreservesSourceAndExistingDestinationOnFailure() async throws {
        let source = try fixture("source.caf", channels: [[0.1, 0.2, 0.3]])
        let original = try Data(contentsOf: source)
        do {
            _ = try await AudioFileTools.prepareForASR(source: source, destination: source)
            XCTFail("In-place conversion must be rejected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: source), original)
        let alias = directory.appendingPathComponent("hardlink.caf")
        try FileManager.default.linkItem(at: source, to: alias)
        do {
            _ = try await AudioFileTools.prepareForASR(source: source, destination: alias)
            XCTFail("Hard-link alias must be rejected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: source), original)
        let destination = directory.appendingPathComponent("existing.wav")
        try Data("keep me".utf8).write(to: destination)
        do {
            _ = try await AudioFileTools.prepareForASR(source: directory.appendingPathComponent("missing.wav"), destination: destination)
            XCTFail("Missing input must fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep me".utf8))
    }

    func testChunksKeepOffsetsRemainderAndSampleCount() throws {
        let source = try fixture("chunks.caf", channels: [Array(repeating: 0.25, count: 40_000)])
        let chunks = try AudioFileTools.splitForASR(source: source, into: directory, seconds: 1)
        XCTAssertEqual(chunks.map(\.offset), [0, 1, 2])
        XCTAssertEqual(chunks.map(\.duration), [1, 1, 0.5])
        XCTAssertEqual(try chunks.map { try AVAudioFile(forReading: $0.url).length }, [16_000, 16_000, 8_000])
        XCTAssertEqual(try samples(chunks[2].url)[7_999], 0.25, accuracy: 0.001)
    }

    func testExactChunkBoundaryDoesNotCreateEmptyChunk() throws {
        let source = try fixture("exact.caf", channels: [Array(repeating: 0, count: 32_000)])
        XCTAssertEqual(try AudioFileTools.splitForASR(source: source, into: directory, seconds: 1).count, 2)
    }

    func testInvalidChunkDurationsAreRejected() throws {
        let source = try fixture("small.caf", channels: [[0]])
        for duration in [0, -1, Double.nan, Double.infinity, 0.000001] {
            XCTAssertThrowsError(try AudioFileTools.splitForASR(source: source, into: directory, seconds: duration))
        }
    }

    func testGateMasksInitialDisabledAndTimestampedTransitionsBeforeRawWrite() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
        buffer.frameLength = 8
        for frame in 0..<8 { buffer.floatChannelData![0][frame] = 0.8 }
        let events = [
            AudioGateEvent(time: 0, microphoneEnabled: false, paused: false),
            AudioGateEvent(time: 2.0 / 16_000, microphoneEnabled: true, paused: false),
            AudioGateEvent(time: 5.0 / 16_000, microphoneEnabled: false, paused: false)
        ]
        AudioSamplePolicy.applyGate(to: buffer, at: 0, microphone: true, events: events)
        let url = directory.appendingPathComponent("gated.caf")
        let writer = try AudioTimelineWriter(url: url, format: format)
        try writer.append(buffer, at: 0)
        writer.close()
        let stored = try samples(url)
        XCTAssertEqual(stored, [0, 0, 0.8, 0.8, 0.8, 0, 0, 0])
    }

    func testPauseSilencesBothTracksWithoutCompressingTimeline() {
        for microphone in [false, true] {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
            buffer.frameLength = 4
            for frame in 0..<4 { buffer.floatChannelData![0][frame] = 0.5 }
            AudioSamplePolicy.applyGate(to: buffer, at: 0, microphone: microphone, events: [
                AudioGateEvent(time: 0, microphoneEnabled: true, paused: false),
                AudioGateEvent(time: 1.0 / 16_000, microphoneEnabled: true, paused: true),
                AudioGateEvent(time: 3.0 / 16_000, microphoneEnabled: true, paused: false)
            ])
            XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 4)), [0.5, 0, 0, 0.5])
        }
    }

    func testTimelineInsertsHostClockGapsAndTrimsOverlap() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        for frame in 0..<4 { buffer.floatChannelData![0][frame] = Float(frame + 1) / 10 }
        let url = directory.appendingPathComponent("timeline.caf")
        let writer = try AudioTimelineWriter(url: url, format: format)
        try writer.append(buffer, at: 2.0 / 16_000)
        try writer.append(buffer, at: 4.0 / 16_000)
        try writer.append(buffer, at: 10.0 / 16_000)
        writer.close()
        XCTAssertEqual(try samples(url), [0, 0, 0.1, 0.2, 0.3, 0.4, 0.3, 0.4, 0, 0, 0.1, 0.2, 0.3, 0.4])
    }

    func testAlignedMixPreservesGapsAndUsesHeadroom() throws {
        let system = try fixture("system.caf", channels: [[0, 0, 0.8, 1, -1, 0.4]])
        let mic = try fixture("microphone.caf", channels: [[0, 0.6, 0.6, 1, -1, 0, 0.2]])
        let destination = directory.appendingPathComponent("recording.wav")
        try AudioFileTools.mixAligned(system: system, microphone: mic, destination: destination)
        let output = try samples(destination)
        XCTAssertEqual(output.count, 7)
        for (actual, expected) in zip(output, [Float(0), 0.3, 0.7, 1, -1, 0.2, 0.1]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    func testEmptyAudioDoesNotCreateChunks() throws {
        let source = try fixture("empty.caf", channels: [[]])
        XCTAssertEqual(try AudioFileTools.duration(of: source), 0)
        XCTAssertTrue(try AudioFileTools.splitForASR(source: source, into: directory, seconds: 1).isEmpty)
    }

    func testMicrophoneHoldbackStartsClosedAndDiscardsPendingOnDisableAndStop() {
        let holdback = AudioMicrophoneHoldback()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for frame in 0..<1_600 { buffer.floatChannelData![0][frame] = 0.8 }
        XCTAssertNil(holdback.token)
        holdback.setEnabled(true)
        let firstToken = holdback.token!
        holdback.append(buffer, at: 1, token: firstToken)
        XCTAssertTrue(holdback.takeVerified(at: 3).isEmpty) // Entire buffer must age two seconds.
        let ready = holdback.takeVerified(at: 3.2)
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.time, 1) // Never concatenate away its clock position.
        holdback.append(buffer, at: 4, token: firstToken)
        holdback.setEnabled(false)
        holdback.setEnabled(true)
        holdback.append(buffer, at: 4.5, token: firstToken) // Copy queued before mute.
        XCTAssertTrue(holdback.takeVerified(at: 10).isEmpty)
        holdback.append(buffer, at: 11, token: holdback.token!)
        holdback.discardPending()
        XCTAssertTrue(holdback.takeVerified(at: 20).isEmpty)
    }

    func testNonIntegerRateConversionPreservesWholeFileLengthAcrossBlocks() async throws {
        let source = try fixture("44k.caf", rate: 44_100, channels: [Array(repeating: 0.25, count: 110_250)])
        let output = directory.appendingPathComponent("44k.wav")
        let duration = try await AudioFileTools.prepareForASR(source: source, destination: output)
        XCTAssertEqual(duration, 2.5, accuracy: 0.0001)
        XCTAssertEqual(try AVAudioFile(forReading: output).length, 40_000)
        XCTAssertEqual(try samples(output)[32_000], 0.25, accuracy: 0.001)
    }

    func testMicrophoneMuteDoesNotGateSystemOrClipRawFloatSamples() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        buffer.floatChannelData![0][0] = 1.25
        buffer.floatChannelData![0][1] = -1.25
        buffer.floatChannelData![0][2] = .nan
        AudioSamplePolicy.applyGate(to: buffer, at: 1, microphone: false,
                                    events: [AudioGateEvent(time: 0, microphoneEnabled: false, paused: false)])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 3)), [1.25, -1.25, 0])
    }

    func testDroppedHoldbackFramesBecomeSilenceInRawFile() throws {
        let holdback = AudioMicrophoneHoldback()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for frame in 0..<1_600 { buffer.floatChannelData![0][frame] = 0.75 }
        let url = directory.appendingPathComponent("held-raw.caf")
        let writer = try AudioTimelineWriter(url: url, format: format)
        holdback.setEnabled(true)
        holdback.append(buffer, at: 1, token: holdback.token!)
        for frame in holdback.takeVerified(at: 3.2) { try writer.append(frame.buffer, at: frame.time) }
        holdback.append(buffer, at: 4, token: holdback.token!)
        holdback.setEnabled(false)
        holdback.setEnabled(true)
        holdback.append(buffer, at: 5, token: holdback.token!)
        holdback.discardPending() // stop discards even if those frames would later age out
        for frame in holdback.takeVerified(at: 10) { try writer.append(frame.buffer, at: frame.time) }
        try writer.pad(to: 6)
        XCTAssertEqual(writer.frames, 96_000)
        writer.close()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 96_000)
        let raw = try samples(url)
        XCTAssertEqual(raw.count, 96_000)
        XCTAssertEqual(raw[16_500], 0.75)
        XCTAssertTrue(raw[17_600...].allSatisfy { $0 == 0 })
    }

    func testMicrophoneHoldbackRejectsUnboundedPendingBuffers() {
        let holdback = AudioMicrophoneHoldback()
        holdback.setEnabled(true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        var rejected = false
        for _ in 0..<1_000 {
            if !holdback.append(buffer, at: 100, token: holdback.token!) { rejected = true; break }
        }
        XCTAssertTrue(rejected)
        holdback.discardPending()
        XCTAssertTrue(holdback.append(buffer, at: 101, token: holdback.token!))
    }
}
