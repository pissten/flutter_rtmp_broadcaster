import Flutter
import Foundation
import AVFoundation
import QuartzCore
import LFLiveKit

@objc
public class FlutterRTMPStreaming: NSObject, LFLiveSessionDelegate {
    private let eventSink: FlutterEventSink
    private var liveSession: LFLiveSession?
    private var isPublishing = false
    private var isPaused = false
    private var latestDebugInfo: LFLiveDebug?
    private var latestState: LFLiveState = .ready
    private var activePublishUrl: String = ""
    // One serial queue: preserves delegate submission order and lets us use
    // CMSampleBuffer PTS for both paths (LFLive default NOW on separate queues
    // can be non-monotonic vs capture → periodic MSE/player stalls).
    private let pushMediaQueue = DispatchQueue(label: "rigatta.lflive.pushMedia", qos: .userInitiated)

    @objc
    public init(sink: @escaping FlutterEventSink) {
        self.eventSink = sink
        super.init()
    }

    @objc
    public func open(url: String, width: Int, height: Int, bitrate: Int) {
        closeInternal(emitStoppedEvent: false)

        let normalizedUrl = normalizeUrlForLFLive(url)
        activePublishUrl = normalizedUrl

        // CRITICAL: encoder size MUST match the actual capture size, otherwise
        // VTCompressionSession scales internally and exhausts its bounded pool
        // (~8 frames) → pushVideo blocks permanently after ~8 frames.
        let effectiveWidth = width > 0 ? width : 480
        let effectiveHeight = height > 0 ? height : 720
        // Ceiling from Dart (e.g. 1 Mbps). Start low; LFLive adaptiveBitrate ramps toward max when buffer allows.
        let ceilingBps = UInt(bitrate > 0 ? bitrate : 1_000_000)
        let startBps = UInt(
            max(
                200_000,
                min(Int(Double(ceilingBps) * 0.35), Int(ceilingBps))
            )
        )
        let minBps = UInt(
            max(
                120_000,
                min(Int(Double(ceilingBps) * 0.22), Int(startBps) - 20_000)
            )
        )
        let videoFps: UInt = 30
        // ~1 s GOP at 30 fps: fewer/larger IDR bursts than 0.5s GOP, smoother for RTMP/MSE.
        let gopFrames: UInt = 30
        NSLog(
            "[RIGATTA-LF] open size=\(effectiveWidth)x\(effectiveHeight) start=\(startBps) max=\(ceilingBps) min=\(minBps) adaptive=ON fps=\(videoFps) gop=\(gopFrames)"
        )

        let audioConfig = LFLiveAudioConfiguration.defaultConfiguration(for: LFLiveAudioQuality.high)
        let videoConfig = LFLiveVideoConfiguration()
        videoConfig.videoSize = CGSize(width: effectiveWidth, height: effectiveHeight)
        videoConfig.videoBitRate = startBps
        videoConfig.videoMaxBitRate = ceilingBps
        // LFLive adaptive steps down toward min; keep min clearly below start so +50k / −100k can move.
        let adaptiveFloor = UInt(max(120_000, min(Int(minBps), Int(startBps) - 50_000)))
        videoConfig.videoMinBitRate = adaptiveFloor
        videoConfig.videoFrameRate = videoFps
        videoConfig.videoMaxKeyframeInterval = gopFrames

        // LFLiveInputMaskAll (raw value 12): external audio + external video.
        let captureType = LFLiveCaptureTypeMask(rawValue: 12)!
        let session = LFLiveSession(
            audioConfiguration: audioConfig,
            videoConfiguration: videoConfig,
            captureType: captureType
        )
        session?.delegate = self
        session?.showDebugInfo = true
        session?.adaptiveBitrate = true
        session?.reconnectCount = 0
        session?.reconnectInterval = 1
        liveSession = session

        emit([
            "event": "rtmp_debug_split",
            "connectUrl": normalizedUrl,
            "publishName": "",
            "errorDescription": ""
        ])

        let stream = LFLiveStreamInfo()
        stream.url = normalizedUrl
        liveSession?.startLive(stream)

        isPublishing = true
        isPaused = false
        emit([
            "event": "rtmp_status",
            "code": "NetConnection.Connect.Pending",
            "level": "status",
            "errorDescription": ""
        ])
    }

    @objc
    public func addVideoData(buffer: CMSampleBuffer) {
        guard isPublishing, !isPaused else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
        let tsMs = Self.millisFromSampleBufferPts(buffer)
        // Explicit retain so buffer cannot be reclaimed by AVCapture pool
        // before the async block runs the encoder. Released after pushVideo.
        let retained = Unmanaged.passRetained(imageBuffer)
        pushMediaQueue.async { [weak self] in
            defer { retained.release() }
            guard let self = self, self.isPublishing, !self.isPaused else { return }
            RigattaWatchdogTickPushVideoEnter()
            self.liveSession?.pushVideo(retained.takeUnretainedValue(), timeStampMs: tsMs)
            RigattaWatchdogTickPushVideoExit()
        }
    }

    @objc
    public func addAudioData(buffer: CMSampleBuffer) {
        guard isPublishing, !isPaused else { return }
        guard let pcmData = pcmDataFromSampleBuffer(buffer) else { return }
        let tsMs = Self.millisFromSampleBufferPts(buffer)
        pushMediaQueue.async { [weak self] in
            guard let self = self, self.isPublishing, !self.isPaused else { return }
            RigattaWatchdogTickPushAudioEnter()
            self.liveSession?.pushAudio(pcmData, timeStampMs: tsMs)
            RigattaWatchdogTickPushAudioExit()
        }
    }

    /// Presentation time in milliseconds (same master clock for audio + video from AVCapture).
    private static func millisFromSampleBufferPts(_ sampleBuffer: CMSampleBuffer) -> UInt64 {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !CMTIME_IS_VALID(pts) || CMTIME_IS_INDEFINITE(pts) {
            return UInt64(CACurrentMediaTime() * 1000.0)
        }
        let seconds = CMTimeGetSeconds(pts)
        if seconds.isNaN || seconds.isInfinite || seconds < 0 {
            return UInt64(CACurrentMediaTime() * 1000.0)
        }
        return UInt64(seconds * 1000.0)
    }

    private func pcmDataFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        var length: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let pointer = dataPointer, totalLength > 0 else {
            return nil
        }
        return Data(bytes: pointer, count: totalLength)
    }

    @objc
    public func pauseVideoStreaming() {
        isPaused = true
    }

    @objc
    public func resumeVideoStreaming() {
        isPaused = false
    }

    @objc
    public func getStreamStatistics() -> NSDictionary {
        let debug = latestDebugInfo
        return [
            "state": Int(latestState.rawValue),
            "isPublishing": isPublishing,
            "isPaused": isPaused,
            "currentBandwidth": debug?.currentBandwidth ?? 0,
            "bandwidth": debug?.bandwidth ?? 0,
            "dropFrame": debug?.dropFrame ?? 0,
            "totalFrame": debug?.totalFrame ?? 0,
            "capturedAudioCount": debug?.capturedAudioCount ?? 0,
            "capturedVideoCount": debug?.capturedVideoCount ?? 0,
            "unSendCount": debug?.unSendCount ?? 0
        ]
    }

    @objc
    public func close() {
        closeInternal(emitStoppedEvent: true)
    }

    public func liveSession(_ session: LFLiveSession?, liveStateDidChange state: LFLiveState) {
        latestState = state
        NSLog("[RIGATTA-LF] liveStateDidChange: \(state.rawValue) url=\(activePublishUrl)")
        switch state {
        case .ready:
            emitStatus(code: "NetConnection.Connect.Ready", level: "status", description: "")
        case .pending:
            emitStatus(code: "NetConnection.Connect.Pending", level: "status", description: "")
        case .start:
            emitStatus(code: "NetStream.Publish.Start", level: "status", description: "")
            emit(["event": "rtmp_connected", "errorDescription": ""])
        case .stop:
            isPublishing = false
            emit(["event": "rtmp_stopped", "errorDescription": "rtmp stopped"])
        case .error:
            isPublishing = false
            emitStatus(code: "NetConnection.Connect.Failed", level: "error", description: "LFLive state error")
            emit(["event": "rtmp_stream_error", "errorDescription": "LFLive state error"])
        default:
            emitStatus(code: "LFLiveState.\(state.rawValue)", level: "status", description: "")
        }
    }

    public func liveSession(_ session: LFLiveSession?, errorCode: LFLiveSocketErrorCode) {
        let message = "LFLive socket error \(errorCode.rawValue)"
        NSLog("[RIGATTA-LF] socket error: \(message) url=\(activePublishUrl)")
        emitStatus(code: "NetConnection.Connect.Failed", level: "error", description: message)
        emit(["event": "rtmp_stream_error", "errorDescription": message])
    }

    public func liveSession(_ session: LFLiveSession?, debugInfo: LFLiveDebug?) {
        latestDebugInfo = debugInfo
        if let debugInfo {
            NSLog("[RIGATTA-LF] debug bandwidth=\(debugInfo.currentBandwidth) drop=\(debugInfo.dropFrame) unsent=\(debugInfo.unSendCount)")
        }
        emit([
            "event": "rtmp_probe",
            "bytesOut": Int(debugInfo?.dataFlow ?? 0),
            "bytesIn": 0,
            "currentBandwidth": Int(debugInfo?.currentBandwidth ?? 0),
            "bandwidth": Int(debugInfo?.bandwidth ?? 0),
            "dropFrame": debugInfo?.dropFrame ?? 0,
            "totalFrame": debugInfo?.totalFrame ?? 0,
            "unSendCount": debugInfo?.unSendCount ?? 0,
            "capturedVideoCount": debugInfo?.capturedVideoCount ?? 0,
            "capturedAudioCount": debugInfo?.capturedAudioCount ?? 0,
            "errorDescription": ""
        ])
    }

    private func closeInternal(emitStoppedEvent: Bool) {
        if let session = liveSession {
            session.stopLive()
            session.running = false
            session.delegate = nil
        }
        liveSession = nil
        isPublishing = false
        isPaused = false
        latestDebugInfo = nil
        latestState = .ready
        activePublishUrl = ""

        if emitStoppedEvent {
            emit(["event": "rtmp_stopped", "errorDescription": "rtmp disconnected"])
        }
    }

    private func emitStatus(code: String, level: String, description: String) {
        emit([
            "event": "rtmp_status",
            "code": code,
            "level": level,
            "errorDescription": description
        ])
    }

    private func emit(_ payload: [String: Any]) {
        DispatchQueue.main.async {
            self.eventSink(payload)
        }
    }

    private func normalizeUrlForLFLive(_ url: String) -> String {
        guard var components = URLComponents(string: url),
              components.scheme?.lowercased() == "rtmp" else {
            return url
        }
        if components.port == 1935 {
            components.port = nil
            return components.string ?? url
        }
        return url
    }
}
