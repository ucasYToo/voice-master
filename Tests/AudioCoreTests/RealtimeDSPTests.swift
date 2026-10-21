import AudioToolbox
import RealtimeDSP
import Testing

private final class TestAudioBuffers {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    private let allocation: UnsafeMutableRawPointer
    private var sampleStorage: [UnsafeMutablePointer<Float>] = []
    let layouts: [Int]
    let frames: Int

    init(channels: [Int], frames: Int, initial: Float = 0) {
        precondition(!channels.isEmpty)
        self.layouts = channels
        self.frames = frames
        allocation = .allocate(
            byteCount: MemoryLayout<AudioBufferList>.size + (channels.count - 1) * MemoryLayout<AudioBuffer>.stride,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        pointer = allocation.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.initialize(to: AudioBufferList(mNumberBuffers: UInt32(channels.count), mBuffers: AudioBuffer()))
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        for (index, count) in channels.enumerated() {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: max(1, count * frames))
            samples.initialize(repeating: initial, count: max(1, count * frames))
            sampleStorage.append(samples)
            buffers[index] = AudioBuffer(
                mNumberChannels: UInt32(count),
                mDataByteSize: UInt32(count * frames * MemoryLayout<Float>.stride),
                mData: UnsafeMutableRawPointer(samples)
            )
        }
    }

    deinit {
        for (index, samples) in sampleStorage.enumerated() {
            samples.deinitialize(count: max(1, layouts[index] * frames))
            samples.deallocate()
        }
        pointer.deinitialize(count: 1)
        allocation.deallocate()
    }

    subscript(buffer: Int, frame: Int, channel: Int) -> Float {
        get { sampleStorage[buffer][frame * layouts[buffer] + channel] }
        set { sampleStorage[buffer][frame * layouts[buffer] + channel] = newValue }
    }

    var samples: [Float] {
        sampleStorage.enumerated().flatMap { index, storage in
            Array(UnsafeBufferPointer(start: storage, count: layouts[index] * frames))
        }
    }
}

struct RealtimeDSPTests {
    private func render(_ state: OpaquePointer, _ input: TestAudioBuffers, _ output: TestAudioBuffers) {
        var now = AudioTimeStamp()
        var inputTime = AudioTimeStamp()
        var outputTime = AudioTimeStamp()
        #expect(MVAudioIOProc(0, &now, input.pointer, &inputTime, output.pointer, &outputTime, UnsafeMutableRawPointer(state)) == noErr)
    }

    @Test
    func testUnityPreservesLowAmplitudeInterleavedStereoAndMeters() throws {
        let state = try #require(MVRenderStateCreate(48_000, 0, 2, 1))
        defer { MVRenderStateDestroy(state) }
        let input = TestAudioBuffers(channels: [2], frames: 64)
        let output = TestAudioBuffers(channels: [2], frames: 64, initial: 99)
        for frame in 0..<64 {
            input[0, frame, 0] = Float(frame - 32) / 64
            input[0, frame, 1] = -input[0, frame, 0] * 0.5
        }
        render(state, input, output)
        #expect(input.samples == output.samples)
        let metrics = MVRenderReadMetrics(state)
        #expect(metrics.inputPeak == 0.5)
        #expect(metrics.outputPeak == 0.5)
        #expect(metrics.callbackCount == 1)
        #expect(metrics.invalidBuffers == 0)
        #expect(metrics.limitedFrames == 0)
    }

    @Test
    func testSilenceAndInitialZeroGainStaySilent() throws {
        for gain: Float in [0, 4] {
            let state = try #require(MVRenderStateCreate(48_000, 0, 2, gain))
            defer { MVRenderStateDestroy(state) }
            let input = TestAudioBuffers(channels: [2], frames: 64, initial: gain == 0 ? 0.7 : 0)
            let output = TestAudioBuffers(channels: [2], frames: 64, initial: 99)
            render(state, input, output)
            #expect(output.samples.allSatisfy { $0 == 0 })
            #expect(MVRenderReadMetrics(state).outputPeak == 0)
        }
    }

    @Test
    func testLimiterIsBoundedAndPreservesStereoRatioAndPolarity() throws {
        let state = try #require(MVRenderStateCreate(48_000, 0, 2, 4))
        defer { MVRenderStateDestroy(state) }
        let input = TestAudioBuffers(channels: [2], frames: 32)
        let output = TestAudioBuffers(channels: [2], frames: 32)
        for frame in 0..<32 {
            input[0, frame, 0] = frame.isMultiple(of: 2) ? 1 : -1
            input[0, frame, 1] = -input[0, frame, 0] * 0.25
        }
        render(state, input, output)
        #expect(output.samples.allSatisfy { $0.isFinite && abs($0) <= 0.981 })
        for frame in 0..<32 {
            #expect(abs((output[0, frame, 1]) - (-output[0, frame, 0] * 0.25)) <= 0.000001)
            #expect(output[0, frame, 0] * input[0, frame, 0] > 0)
        }
        #expect(MVRenderReadMetrics(state).limitedFrames == 32)
    }

    @Test
    func testPlanarTapOffsetAndExtraOutputChannelsAreHandled() throws {
        let state = try #require(MVRenderStateCreate(44_100, 2, 2, 2))
        defer { MVRenderStateDestroy(state) }
        let input = TestAudioBuffers(channels: [2, 1, 1], frames: 8)
        let output = TestAudioBuffers(channels: [1, 1, 2], frames: 8, initial: 99)
        for frame in 0..<8 {
            input[0, frame, 0] = 99 // Physical microphone channels must not be read.
            input[0, frame, 1] = 99
            input[1, frame, 0] = 0.1
            input[2, frame, 0] = -0.2
        }
        render(state, input, output)
        for frame in 0..<8 {
            #expect(abs((output[0, frame, 0]) - (0.2)) <= 0.000001)
            #expect(abs((output[1, frame, 0]) - (-0.4)) <= 0.000001)
            #expect(output[2, frame, 0] == 0)
            #expect(output[2, frame, 1] == 0)
        }
        #expect(abs((MVRenderReadMetrics(state).inputPeak) - (0.2)) <= 0.000001)
    }

    @Test
    func testMonoOutputAveragesStereo() throws {
        let state = try #require(MVRenderStateCreate(48_000, 0, 1, 1))
        defer { MVRenderStateDestroy(state) }
        let input = TestAudioBuffers(channels: [2], frames: 8)
        let output = TestAudioBuffers(channels: [1], frames: 8)
        for frame in 0..<8 {
            input[0, frame, 0] = 0.6
            input[0, frame, 1] = -0.2
        }
        render(state, input, output)
        #expect(output.samples.allSatisfy { abs($0 - 0.2) < 0.000001 })
    }

    @Test
    func testNonFiniteSampleSilencesEntireBlock() throws {
        for invalid: Float in [.nan, .infinity, -.infinity] {
            let state = try #require(MVRenderStateCreate(48_000, 0, 2, 1))
            defer { MVRenderStateDestroy(state) }
            let input = TestAudioBuffers(channels: [2], frames: 16, initial: 0.25)
            input[0, 15, 1] = invalid
            let output = TestAudioBuffers(channels: [2], frames: 16, initial: 99)
            render(state, input, output)
            #expect(output.samples.allSatisfy { $0 == 0 })
            #expect(MVRenderReadMetrics(state).invalidBuffers == 1)
        }
    }

    @Test
    func testShortAndMissingInputFailSilent() throws {
        let state = try #require(MVRenderStateCreate(48_000, 0, 2, 1))
        defer { MVRenderStateDestroy(state) }
        let short = TestAudioBuffers(channels: [2], frames: 7, initial: 0.5)
        let output = TestAudioBuffers(channels: [2], frames: 8, initial: 99)
        render(state, short, output)
        #expect(output.samples.allSatisfy { $0 == 0 })
        let missing = TestAudioBuffers(channels: [1], frames: 8, initial: 0.5)
        render(state, missing, output)
        #expect(output.samples.allSatisfy { $0 == 0 })
        #expect(MVRenderReadMetrics(state).invalidBuffers == 2)
    }

    @Test
    func testInvalidByteLengthAndNilInputStorageFailSilent() throws {
        let state = try #require(MVRenderStateCreate(48_000, 0, 2, 1))
        defer { MVRenderStateDestroy(state) }
        let input = TestAudioBuffers(channels: [2], frames: 8, initial: 0.5)
        let output = TestAudioBuffers(channels: [2], frames: 8, initial: 99)
        let buffers = UnsafeMutableAudioBufferListPointer(input.pointer)
        buffers[0].mDataByteSize -= 1
        render(state, input, output)
        #expect(output.samples.allSatisfy { $0 == 0 })
        buffers[0].mDataByteSize += 1
        buffers[0].mData = nil
        render(state, input, output)
        #expect(output.samples.allSatisfy { $0 == 0 })
        #expect(MVRenderReadMetrics(state).invalidBuffers == 2)
    }

    @Test
    func testExtremeFiniteInputRemainsFinite() throws {
        let state = try #require(MVRenderStateCreate(48_000, 0, 2, 4))
        defer { MVRenderStateDestroy(state) }
        let input = TestAudioBuffers(channels: [2], frames: 8, initial: Float.greatestFiniteMagnitude)
        let output = TestAudioBuffers(channels: [2], frames: 8)
        render(state, input, output)
        #expect(output.samples.allSatisfy { $0.isFinite && $0 > 0.9 && $0 < 1 })
        #expect(MVRenderReadMetrics(state).invalidBuffers == 0)
    }

    @Test
    func testGainClampAndSmoothChange() throws {
        let state = try #require(MVRenderStateCreate(48_000, 0, 2, 100))
        defer { MVRenderStateDestroy(state) }
        let input = TestAudioBuffers(channels: [2], frames: 4_096, initial: 0.1)
        let output = TestAudioBuffers(channels: [2], frames: 4_096)
        render(state, input, output)
        #expect(abs((output[0, 0, 0]) - (0.4)) <= 0.000001)
        MVRenderSetGain(state, -100)
        render(state, input, output)
        #expect(output[0, 0, 0] < 0.4)
        #expect(output[0, 0, 0] > 0.39)
        #expect(abs(output[0, 4_095, 0]) < 0.000001)
        MVRenderSetGain(state, .nan)
        render(state, input, output)
        #expect(output.samples.allSatisfy { $0.isFinite && abs($0) < 0.000001 })
        #expect(output[0, 4_095, 0] == 0)
    }

    @Test
    func testRejectsInvalidConfiguration() {
        #expect(MVRenderStateCreate(0, 0, 2, 1) == nil)
        #expect(MVRenderStateCreate(.nan, 0, 2, 1) == nil)
        #expect(MVRenderStateCreate(48_000, UInt32.max, 2, 1) == nil)
        #expect(MVRenderStateCreate(48_000, 0, 0, 1) == nil)
        #expect(MVRenderStateCreate(48_000, 0, 3, 1) == nil)
    }
}
