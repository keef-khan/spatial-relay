import AVFoundation
import CoreMedia
import Foundation

enum OutputReconfigurationGrace {
    static let durationMilliseconds: UInt64 = 5_000
    static let durationNanoseconds = durationMilliseconds * 1_000_000

    static func contains(
        startUptimeNanoseconds: UInt64,
        nowUptimeNanoseconds: UInt64
    ) -> Bool {
        guard nowUptimeNanoseconds >= startUptimeNanoseconds else { return true }
        return nowUptimeNanoseconds - startUptimeNanoseconds <= durationNanoseconds
    }
}

enum RendererRecoveryTimeline {
    static func restartFrame(
        currentTime: CMTime,
        suggestedFlushTime: CMTime?,
        timescale: CMTimeScale,
        fallbackFrame: Int64
    ) -> Int64 {
        guard timescale > 0 else { return max(0, fallbackFrame) }

        let candidates = [currentTime, suggestedFlushTime]
            .compactMap { $0 }
            .filter(\.isNumeric)
            .map {
                CMTimeConvertScale(
                    $0,
                    timescale: timescale,
                    method: .roundTowardPositiveInfinity
                )
            }
            .filter(\.isNumeric)
            .map(\.value)

        return max(0, candidates.max() ?? fallbackFrame)
    }
}

enum RendererQueueWindow {
    static func canEnqueue(
        nextFrame: Int64,
        playhead: CMTime,
        timescale: CMTimeScale,
        segmentStartFrame: Int64,
        timelineIsRunning: Bool
    ) -> Bool {
        guard timescale > 0 else { return false }
        let reference: Int64
        if timelineIsRunning, playhead.isNumeric {
            reference = CMTimeConvertScale(playhead, timescale: timescale, method: .roundTowardZero).value
        } else {
            reference = segmentStartFrame
        }
        return Double(nextFrame) - Double(reference) < Double(timescale) * 0.25
    }
}

final class SampleBufferPlayer: @unchecked Sendable {
    typealias FailureHandler = @Sendable (Error) -> Void

    private let capture: SRAudioCaptureBridge
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let serializationQueue = DispatchQueue(label: "com.shevlfs.SpatialRelay.sample-buffer-player")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let factory: PCMSampleBufferFactory
    private let sampleRate: Double
    private let timeScale: CMTimeScale
    private let prebufferFrameCount: Int64
    private let onFailure: FailureHandler

    // Kept type-erased so the app still launches on macOS 14.2–26.
    // All receiver access is confined to serializationQueue.
    private var modernReceiver: Any?
    private var configurationChangeCount = 0
    private var automaticFlushCount = 0
    private var lastRecovery = "None"
    private var timer: DispatchSourceTimer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var nextFrame: Int64 = 0
    private var segmentStartFrame: Int64 = 0
    private var enqueuedFrameCount: Int64 = 0
    private var timelineIsRunning = false
    private var backpressureStartTime: DispatchTime?
    private var pauseTransitionStartTime: DispatchTime?
    private var lastRendererConfigurationChangeTime: DispatchTime?
    private var rendererRecoveryIsActive = false
    private var formatRecoveryStartTime: DispatchTime?
    private var capturedFramesAtFormatMismatch: UInt64 = 0
    private var observedFormatMismatchCount: UInt64 = 0
    private var failureWasDelivered = false
    private var isStarted = false

    init(
        capture: SRAudioCaptureBridge,
        sampleRate: Double,
        onFailure: @escaping FailureHandler
    ) throws {
        let roundedRate = sampleRate.rounded()
        guard roundedRate > 0, roundedRate <= Double(Int32.max) else {
            throw RelayError.unsupportedTapFormat("invalid sample rate \(sampleRate)")
        }
        self.capture = capture
        self.sampleRate = sampleRate
        self.timeScale = CMTimeScale(roundedRate)
        self.onFailure = onFailure
        self.factory = try PCMSampleBufferFactory(sampleRate: sampleRate)
        self.prebufferFrameCount = max(2_048, Int64(sampleRate * 0.08))
        // Leave audioOutputDeviceUniqueID at its documented nil default. Even
        // assigning nil invokes AVFoundation's device reconfiguration setter;
        // that setter raised an Objective-C exception during testing on macOS 27.2.
        // The coordinator still stops capture when the actual output changes.
        serializationQueue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    func start() {
        performSync {
            guard !isStarted else { return }
            isStarted = true
            failureWasDelivered = false
            nextFrame = 0
            segmentStartFrame = 0
            enqueuedFrameCount = 0
            timelineIsRunning = false
            backpressureStartTime = nil
            pauseTransitionStartTime = nil
            lastRendererConfigurationChangeTime = nil
            rendererRecoveryIsActive = false
            formatRecoveryStartTime = nil
            capturedFramesAtFormatMismatch = 0
            observedFormatMismatchCount = 0

            // Audio-only renderers default to multichannel spatialization. This explicit
            // opt-in is what makes ordinary two-channel PCM eligible for Spatialize Stereo.
            renderer.allowedAudioSpatializationFormats = .monoAndStereo
            renderer.volume = 1
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
            attachRenderer()
            synchronizer.setRate(0, time: .zero)

            installRendererObservers()

            let timer = DispatchSource.makeTimerSource(queue: serializationQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                self?.pump()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        performSync {
            guard isStarted else { return }
            isStarted = false

            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil

            synchronizer.setRate(0, time: .invalid)
            flushRenderer()
            // The receiver remains owned by this player until the coordinator
            // releases it. Legacy renderers retain their original detach path.
            if modernReceiver == nil {
                synchronizer.removeRenderer(renderer, at: .invalid, completionHandler: nil)
            }
            removeRendererObservers()

            timelineIsRunning = false
            nextFrame = 0
            segmentStartFrame = 0
            enqueuedFrameCount = 0
            backpressureStartTime = nil
            pauseTransitionStartTime = nil
            lastRendererConfigurationChangeTime = nil
            rendererRecoveryIsActive = false
            formatRecoveryStartTime = nil
            capturedFramesAtFormatMismatch = 0
            observedFormatMismatchCount = 0
        }
    }

    /// The renderer owns output-mode changes, while the coordinator owns route
    /// health. Exposing only this bounded grace prevents a normal Spatial Audio
    /// reconfiguration from being mistaken for a disconnected device.
    func isWithinOutputReconfigurationGracePeriod() -> Bool {
        performSync {
            guard let start = lastRendererConfigurationChangeTime else { return false }
            return OutputReconfigurationGrace.contains(
                startUptimeNanoseconds: start.uptimeNanoseconds,
                nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        }
    }

    private func pump() {
        guard isStarted && !failureWasDelivered else { return }

        if renderer.status == .failed {
            // AVQueuedSampleBufferRenderingStatus.failed is terminal. Normal
            // spatial-output changes are handled by the notifications below;
            // retaining Spotify's muted tap for five seconds cannot recover a
            // renderer that has actually entered this state.
            deliverFailure(RelayError.rendererFailed(renderer.error?.localizedDescription ?? "unknown renderer error"))
            return
        }

        let mismatchCount = capture.formatMismatchCount
        if mismatchCount > observedFormatMismatchCount {
            observedFormatMismatchCount = mismatchCount
            if formatRecoveryStartTime == nil {
                formatRecoveryStartTime = .now()
                capturedFramesAtFormatMismatch = capture.capturedFrameCount
            }
        }
        if let formatRecoveryStartTime {
            if capture.capturedFrameCount > capturedFramesAtFormatMismatch {
                self.formatRecoveryStartTime = nil
            } else if elapsedMilliseconds(since: formatRecoveryStartTime) > OutputReconfigurationGrace.durationMilliseconds {
                deliverFailure(RelayError.captureFailed("the tap buffer layout did not recover after the output change"))
                return
            } else {
                return
            }
        }

        if capture.droppedFrameCount > 0 {
            deliverFailure(RelayError.captureFailed("the live audio buffer overflowed"))
            return
        }

        // setRate(_:time:) completes asynchronously. Keep new PCM in the ring
        // until the synchronizer confirms it is paused, rather than relying on
        // a fixed delay under load.
        if let pauseTransitionStartTime {
            if abs(synchronizer.rate) < 0.000_1 {
                self.pauseTransitionStartTime = nil
            } else if elapsedMilliseconds(since: pauseTransitionStartTime) > OutputReconfigurationGrace.durationMilliseconds {
                deliverFailure(RelayError.rendererFailed("the render timeline did not pause"))
                return
            } else {
                return
            }
        }

        if rendererRecoveryIsActive,
           timelineIsRunning,
           abs(synchronizer.rate - 1) < 0.000_1 {
            rendererRecoveryIsActive = false
        }

        // If the control queue was delayed while Spotify was silent, the
        // synchronizer may already be beyond the last queued frame when audio
        // resumes. Rebase before enqueueing so new PCM is never timestamped in
        // the past.
        if timelineIsRunning, capture.availableFrameCount > 0 {
            let playhead = synchronizer.currentTime()
            if playhead.isNumeric,
               CMTimeCompare(playhead, mediaTime(forFrame: nextFrame)) >= 0 {
                resetTimeline(at: playhead)
                return
            }
        }

        var receivedData = false
        while isReadyForMoreMediaData,
              let chunk = capture.dequeueChunk(withMaximumFrameCount: 1_024) {
            do {
                if enqueuedFrameCount == 0 {
                    segmentStartFrame = nextFrame
                }
                let sampleBuffer = try factory.makeSampleBuffer(
                    data: chunk.data,
                    frameCount: chunk.frameCount,
                    startingAtFrame: nextFrame
                )
                // Account first: a successful enqueue can also request a flush,
                // which rebases these counters before the next sample is made.
                nextFrame += Int64(chunk.frameCount)
                enqueuedFrameCount += Int64(chunk.frameCount)
                guard enqueue(sampleBuffer) else { return }
                receivedData = true
            } catch {
                deliverFailure(error)
                return
            }
        }

        if receivedData {
            backpressureStartTime = nil
        } else if capture.availableFrameCount >= UInt32(prebufferFrameCount),
                  !isReadyForMoreMediaData {
            if let backpressureStartTime {
                if elapsedMilliseconds(since: backpressureStartTime) > OutputReconfigurationGrace.durationMilliseconds {
                    deliverFailure(RelayError.rendererFailed("the renderer stopped accepting audio"))
                    return
                }
            } else {
                backpressureStartTime = .now()
            }
        } else {
            backpressureStartTime = nil
        }

        if !timelineIsRunning,
           enqueuedFrameCount >= prebufferFrameCount {
            synchronizer.setRate(1, time: mediaTime(forFrame: segmentStartFrame))
            timelineIsRunning = true
        }

        // The ring is normally empty while the renderer stays prebuffered. When
        // its playhead actually reaches the final queued sample, freeze there;
        // this handles even very short Spotify pauses without creating late PTS.
        if timelineIsRunning, capture.availableFrameCount == 0 {
            let playhead = synchronizer.currentTime()
            let queuedEnd = mediaTime(forFrame: nextFrame)
            if playhead.isNumeric, CMTimeCompare(playhead, queuedEnd) >= 0 {
                resetTimeline(at: playhead)
            }
        }
    }

    private func resetTimeline(at playhead: CMTime) {
        let converted = CMTimeConvertScale(
            playhead,
            timescale: timeScale,
            method: .roundTowardPositiveInfinity
        )
        let restartFrame = converted.isNumeric ? max(nextFrame, converted.value) : nextFrame
        let restartTime = mediaTime(forFrame: restartFrame)

        synchronizer.setRate(0, time: restartTime)
        flushRenderer()
        nextFrame = restartFrame
        segmentStartFrame = restartFrame
        enqueuedFrameCount = 0
        timelineIsRunning = false
        backpressureStartTime = nil
        pauseTransitionStartTime = .now()
    }

    /// Preserve the live timebase during a hardware/spatial-mode transition.
    /// Apple's automatic-flush contract allows re-enqueueing at currentTime();
    /// stopping/restarting the session here unnecessarily interrupts mode changes.
    private func recoverRendererAfterConfigurationChange(suggestedFlushTime: CMTime? = nil) {
        guard isStarted && !failureWasDelivered else { return }
        lastRendererConfigurationChangeTime = .now()
        rendererRecoveryIsActive = true
        let restartFrame = RendererRecoveryTimeline.restartFrame(
            currentTime: synchronizer.currentTime(),
            suggestedFlushTime: suggestedFlushTime,
            timescale: timeScale,
            fallbackFrame: nextFrame
        )
        flushRenderer()
        // Leave room for the next pump rather than enqueueing at a timestamp
        // that will already be in the past when the hardware consumes it.
        nextFrame = restartFrame + (timelineIsRunning ? prebufferFrameCount : 0)
        segmentStartFrame = nextFrame
        enqueuedFrameCount = 0
        backpressureStartTime = nil
        lastRecovery = "Rebased without pausing playback"
    }

    private func attachRenderer() {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            if modernReceiver == nil {
                modernReceiver = synchronizer.sampleBufferReceiver(adding: renderer)
            }
            return
        }
        #endif
        synchronizer.addRenderer(renderer)
    }

    private var isReadyForMoreMediaData: Bool {
        if #available(macOS 27.0, *), modernReceiver != nil {
            return RendererQueueWindow.canEnqueue(
                nextFrame: nextFrame,
                playhead: synchronizer.currentTime(),
                timescale: timeScale,
                segmentStartFrame: segmentStartFrame,
                timelineIsRunning: timelineIsRunning
            )
        }
        return renderer.isReadyForMoreMediaData
    }

    /// Returns false after an error. Never counts a rejected buffer as playing.
    private func enqueue(_ sampleBuffer: sending CMSampleBuffer) -> Bool {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *),
           let receiver = modernReceiver as? AVSampleBufferAudioRenderer.Receiver {
            let ready = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sampleBuffer)
            switch receiver.enqueueImmediately(ready) {
            case .enqueued:
                return true
            case .enqueuedWithSuggestedFlush(let reasons):
                var flushTime: CMTime?
                for reason in reasons {
                    switch reason {
                    case .wasFlushedAutomatically(let time):
                        automaticFlushCount += 1
                        if time.isNumeric,
                           flushTime == nil || CMTimeCompare(time, flushTime!) > 0 {
                            flushTime = time
                        }
                    case .outputConfigurationChanged:
                        configurationChangeCount += 1
                    @unknown default:
                        break
                    }
                }
                recoverRendererAfterConfigurationChange(suggestedFlushTime: flushTime)
                return true
            case .cancelledDueToFlush:
                recoverRendererAfterConfigurationChange()
                return true
            case .cancelledDueToError(let error):
                deliverFailure(RelayError.rendererFailed(error.localizedDescription))
                return false
            @unknown default:
                deliverFailure(RelayError.rendererFailed("Unrecognized audio enqueue result"))
                return false
            }
        }
        #endif
        renderer.enqueue(sampleBuffer)
        return true
    }

    private func flushRenderer() {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *),
           let receiver = modernReceiver as? AVSampleBufferAudioRenderer.Receiver {
            receiver.flush()
            return
        }
        #endif
        renderer.flush()
    }

    func diagnostics() -> String {
        performSync {
            let backend = modernReceiver == nil ? "Legacy renderer" : "macOS 27 receiver"
            return """
            Backend: \(backend)
            Output routing: system default
            Renderer status: \(renderer.status.rawValue)
            Renderer error: \(renderer.error?.localizedDescription ?? "None")
            Timeline rate: \(synchronizer.rate)
            Output configuration events: \(configurationChangeCount)
            Automatic flushes: \(automaticFlushCount)
            Last recovery: \(lastRecovery)
            Captured frames: \(capture.capturedFrameCount)
            Buffered frames: \(capture.availableFrameCount)
            Dropped frames: \(capture.droppedFrameCount)
            Format mismatches: \(capture.formatMismatchCount)
            """
        }
    }

    private func installRendererObservers() {
        // Do not handle the same transition twice: the macOS 27 receiver reports
        // configuration/flush events as part of enqueueImmediately's result.
        if #available(macOS 27.0, *), modernReceiver != nil { return }
        let center = NotificationCenter.default
        let outputToken = center.addObserver(
            forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: renderer,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.serializationQueue.async { [self] in
                self.configurationChangeCount += 1
                self.recoverRendererAfterConfigurationChange()
            }
        }
        notificationTokens.append(outputToken)

        let flushToken = center.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let flushTime = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            self.serializationQueue.async { [self] in
                self.automaticFlushCount += 1
                self.recoverRendererAfterConfigurationChange(suggestedFlushTime: flushTime)
            }
        }
        notificationTokens.append(flushToken)
    }

    private func removeRendererObservers() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll()
    }

    private func deliverFailure(_ error: Error) {
        guard !failureWasDelivered else { return }
        failureWasDelivered = true
        // Do not wait for the main actor to tear down the UI. Stopping the IOProc
        // here immediately releases mutedWhenTapped during renderer failures.
        try? capture.stop()
        onFailure(error)
    }

    private func mediaTime(forFrame frame: Int64) -> CMTime {
        CMTime(value: frame, timescale: timeScale)
    }

    private func elapsedMilliseconds(since time: DispatchTime) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let then = time.uptimeNanoseconds
        guard now >= then else { return 0 }
        return (now - then) / 1_000_000
    }

    private func performSync<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return work()
        }
        return serializationQueue.sync(execute: work)
    }
}

final class PCMSampleBufferFactory {
    private let formatDescription: CMAudioFormatDescription
    private let timescale: CMTimeScale

    init(sampleRate: Double) throws {
        let roundedRate = sampleRate.rounded()
        guard roundedRate > 0, roundedRate <= Double(Int32.max) else {
            throw RelayError.unsupportedTapFormat("invalid sample rate \(sampleRate)")
        }
        timescale = CMTimeScale(roundedRate)

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout(
            mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
            mChannelBitmap: AudioChannelBitmap(rawValue: 0),
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: AudioChannelDescription()
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &format,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        try CoreAudioFailure.check(status, operation: "Creating the stereo PCM description")
        guard let description else {
            throw RelayError.unsupportedTapFormat("Core Media rejected the PCM description")
        }
        formatDescription = description
    }

    func makeSampleBuffer(
        data: Data,
        frameCount: UInt32,
        startingAtFrame: Int64
    ) throws -> CMSampleBuffer {
        guard frameCount > 0, data.count == Int(frameCount) * 8 else {
            throw RelayError.captureFailed("an incomplete PCM chunk was received")
        }

        var blockBuffer: CMBlockBuffer?
        try CoreAudioFailure.check(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            operation: "Allocating an audio block buffer"
        )
        guard let blockBuffer else {
            throw RelayError.captureFailed("Core Media did not allocate an audio buffer")
        }

        let copyStatus = data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        try CoreAudioFailure.check(copyStatus, operation: "Copying a PCM audio chunk")

        var sampleBuffer: CMSampleBuffer?
        let presentationTime = CMTime(value: startingAtFrame, timescale: timescale)
        try CoreAudioFailure.check(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: CMItemCount(frameCount),
                presentationTimeStamp: presentationTime,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            ),
            operation: "Creating a PCM sample buffer"
        )
        guard let sampleBuffer else {
            throw RelayError.captureFailed("Core Media did not create a sample buffer")
        }
        return sampleBuffer
    }
}
