import Flutter
import Foundation
import AVFoundation
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
    // Decouple LFLive push from the camera delegate queue so a blocking pushVideo
    // does not stall AVCapture frame delivery. Concurrent so audio/video do not
    // serialize each other.
    private let pushVideoQueue = DispatchQueue(label: "rigatta.lflive.pushVideo", qos: .userInitiated)
    private let pushAudioQueue = DispatchQueue(label: "rigatta.lflive.pushAudio", qos: .userInitiated)

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
        let requestedBitrate = bitrate > 0 ? bitrate : 1_000_000
        // Low-latency: cap peak bitrate slightly to reduce uplink buffering in MSE/WebRTC chains.
        let effectiveBitrate = min(requestedBitrate, 850_000)
        let videoFps: UInt = 30
        // ~0.5 s GOP at 30 fps — frequent IDR cuts viewer join and end-to-end delay.
        let gopFrames: UInt = 15
        NSLog("[RIGATTA-LF] open size=\(effectiveWidth)x\(effectiveHeight) bitrate=\(effectiveBitrate) (req=\(requestedBitrate)) fps=\(videoFps) gop=\(gopFrames)")

        let audioConfig = LFLiveAudioConfiguration.defaultConfiguration(for: LFLiveAudioQuality.high)
        let videoConfig = LFLiveVideoConfiguration()
        videoConfig.videoSize = CGSize(width: effectiveWidth, height: effectiveHeight)
        videoConfig.videoBitRate = UInt(effectiveBitrate)
        videoConfig.videoMaxBitRate = UInt(effectiveBitrate)
        videoConfig.videoMinBitRate = UInt(max(250_000, Int(Double(effectiveBitrate) * 0.55)))
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
        session?.adaptiveBitrate = false
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
        // Explicit retain so buffer cannot be reclaimed by AVCapture pool
        // before the async block runs the encoder. Released after pushVideo.
        let retained = Unmanaged.passRetained(imageBuffer)
        pushVideoQueue.async { [weak self] in
            defer { retained.release() }
            guard let self = self, self.isPublishing, !self.isPaused else { return }
            RigattaWatchdogTickPushVideoEnter()
            self.liveSession?.pushVideo(retained.takeUnretainedValue())
            RigattaWatchdogTickPushVideoExit()
        }
    }

    @objc
    public func addAudioData(buffer: CMSampleBuffer) {
        guard isPublishing, !isPaused else { return }
        guard let pcmData = pcmDataFromSampleBuffer(buffer) else { return }
        pushAudioQueue.async { [weak self] in
            guard let self = self, self.isPublishing, !self.isPaused else { return }
            RigattaWatchdogTickPushAudioEnter()
            self.liveSession?.pushAudio(pcmData)
            RigattaWatchdogTickPushAudioExit()
        }
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
