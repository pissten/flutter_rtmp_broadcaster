import Flutter
import UIKit
import AVFoundation
import Accelerate
import CoreMotion
import HaishinKit
import os
import ReplayKit
import VideoToolbox

@objc
public class FlutterRTMPStreaming : NSObject {
    private var rtmpConnection = RTMPConnection()
    private var rtmpStream: RTMPStream!
    private var url: String? = nil
    private var name: String? = nil
    private var retries: Int = 0
    private let eventSink: FlutterEventSink
    private let myDelegate = MyRTMPStreamQoSDelagate()
    
    @objc
    public init(sink: @escaping FlutterEventSink) {
        eventSink = sink
    }
    
    @objc
    public func open(url: String, width: Int, height: Int, bitrate: Int) {
        rtmpStream = RTMPStream(connection: rtmpConnection)
        rtmpStream.captureSettings = [
            .sessionPreset: AVCaptureSession.Preset.hd1280x720,
            .continuousAutofocus: true,
            .continuousExposure: true
        ]
        rtmpConnection.addEventListener(.rtmpStatus, selector:#selector(rtmpStatusHandler), observer: self)
        rtmpConnection.addEventListener(.ioError, selector: #selector(rtmpErrorHandler), observer: self)
        
        // Rigatta URL format: rtmp://rtmp.rigatta.no:1935/Event1_DEV-001
        // go2rtc requires: connect("rtmp://host:1935/app") + publish("streamName")
        // Split on last "/" — base URL to connect(), stream name to publish()
        var parts = url.components(separatedBy: "/")
        let streamName = parts.last ?? ""
        parts.removeLast()
        let baseUrl = parts.joined(separator: "/")
        self.url = baseUrl.isEmpty ? url : baseUrl
        self.name = streamName
        print("[RIGATTA-SWIFT] URL split: original='\(url)' base='\(self.url ?? "NIL")' name='\(self.name ?? "NIL")'")
        
        rtmpStream.videoSettings = [
            .width: width,
            .height: height,
            .maxKeyFrameIntervalDuration: 2,
            .bitrate: bitrate
        ]
        rtmpStream.captureSettings = [
            .fps: 30
        ]
        rtmpStream.delegate = myDelegate
        self.retries = 0
        // Run this on the ui thread.
        DispatchQueue.main.async {
            if let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) {
                self.rtmpStream.orientation = orientation
                print(String(format:"Orient %d", orientation.rawValue))
                switch (orientation) {
                case .landscapeLeft, .landscapeRight:
                    self.rtmpStream.videoSettings[.width] = width
                    self.rtmpStream.videoSettings[.height] = height
                    break
                default:
                    break
                }
            }
            self.rtmpConnection.connect(self.url ?? "")
        }
    }

    
    @objc
    private func rtmpStatusHandler(_ notification: Notification) {
        let e = Event.from(notification)
        guard let data: ASObject = e.data as? ASObject, let code: String = data["code"] as? String else {
            return
        }
        print(e)
        switch code {
        case RTMPConnection.Code.connectSuccess.rawValue:
            print("[RIGATTA-SWIFT] rtmpStatusHandler: connectSuccess, publishing name='\(name ?? "NIL")'")
            rtmpStream.publish(name)
            print("[RIGATTA-SWIFT] rtmpStatusHandler: publish() completed successfully")
            retries = 0
            DispatchQueue.main.async { self.eventSink(["event" : "rtmp_connected", "errorDescription" : ""]) }
            break
        case RTMPConnection.Code.connectFailed.rawValue, RTMPConnection.Code.connectClosed.rawValue:
            guard retries <= 3 else {
                DispatchQueue.main.async { self.eventSink(["event" : "error", "errorDescription" : "connection failed " + e.type.rawValue]) }
                return
            }
            retries += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + pow(2.0, Double(retries))) {
                self.rtmpConnection.connect(self.url!)
            }
            DispatchQueue.main.async { self.eventSink(["event" : "rtmp_retry", "errorDescription" : "connection failed " + e.type.rawValue]) }
            break
        default:
            break
        }
    }
    
    @objc
    private func rtmpErrorHandler(_ notification: Notification) {
        if #available(iOS 10.0, *) {
            os_log("%s", notification.name.rawValue)
        }
        guard retries <= 3 else {
            DispatchQueue.main.async { self.eventSink(["event" : "rtmp_stopped", "errorDescription" : "rtmp disconnected"]) }
            return
        }
        retries += 1
        DispatchQueue.global().asyncAfter(deadline: .now() + pow(2.0, Double(retries))) {
            self.rtmpConnection.connect(self.url!)
        }
        DispatchQueue.main.async { self.eventSink(["event" : "rtmp_retry", "errorDescription" : "rtmp disconnected"]) }
    }
    
    @objc
    public func pauseVideoStreaming() {
        rtmpStream.paused = true
    }
    
    @objc
    public func resumeVideoStreaming() {
        rtmpStream.paused = false
    }
    
    @objc
    public func isPaused() -> Bool {
        return rtmpStream.paused
    }
    
    @objc
    public func getStreamStatistics() -> NSDictionary {
        let ret: NSDictionary = [
            "paused": isPaused(),
            "bitrate": rtmpStream.videoSettings[.bitrate]!,
            "width": rtmpStream.videoSettings[.width]!,
            "height": rtmpStream.videoSettings[.height]!,
            "fps": (rtmpStream.captureSettings[.fps]! as! NSNumber).floatValue,
            "orientation": rtmpStream.orientation.rawValue
        ]
        return ret
    }
    
    @objc
    public func addVideoData(buffer: CMSampleBuffer) {
        struct Once { static var done = false }
        if !Once.done {
            print("[RIGATTA-SWIFT] addVideoData: first frame received, rtmpStream=\(rtmpStream != nil ? "OK" : "NIL")")
            Once.done = true
        }
        
        // Only append video if RTMP connection is ready and publishing
        guard rtmpConnection.connected && rtmpStream != nil else {
            print("[RIGATTA-SWIFT] addVideoData: skipping - RTMP not ready")
            return
        }
        
        rtmpStream.appendSampleBuffer(buffer, withType: .video)
    }
    
    @objc
    public func addAudioData(buffer: CMSampleBuffer) {
        // Only append audio if RTMP connection is ready and publishing
        guard rtmpConnection.connected && rtmpStream != nil else {
            print("[RIGATTA-SWIFT] addAudioData: skipping - RTMP not ready")
            return
        }
        
        rtmpStream.appendSampleBuffer(buffer, withType: .audio)
    }
    
    @objc
    public func close() {
        rtmpConnection.close()
    }
    
    // MARK: - Zoom methods (Rigatta addition)
    
    @objc
    public func getMinZoomLevel() -> Double {
        return 1.0
    }
    
    private func currentCaptureDevice() -> AVCaptureDevice? {
        return AVCaptureDevice.default(for: .video)
    }

    @objc
    public func getMaxZoomLevel() -> Double {
        guard let device = currentCaptureDevice() else { return 1.0 }
        return Double(device.activeFormat.videoMaxZoomFactor)
    }
    
    @objc
    public func setZoomLevel(zoom: Double) {
        guard let device = currentCaptureDevice() else { return }
        let clampedZoom = min(max(zoom, 1.0), Double(device.activeFormat.videoMaxZoomFactor))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = CGFloat(clampedZoom)
            device.unlockForConfiguration()
        } catch {
            print("Error setting zoom: \(error)")
        }
    }
}


class MyRTMPStreamQoSDelagate: RTMPStreamDelegate {
    let minBitrate: UInt32 = 300 * 1024
    let maxBitrate: UInt32 = 2500 * 1024
    let incrementBitrate: UInt32 = 512 * 1024
    
    func didPublishSufficientBW(_ stream: RTMPStream, withConnection: RTMPConnection) {
        guard let videoBitrate = stream.videoSettings[.bitrate] as? UInt32 else { return }
        
        var newVideoBitrate = videoBitrate + incrementBitrate
        if newVideoBitrate > maxBitrate {
            newVideoBitrate = maxBitrate
        }
        print("didPublishSufficientBW update: \(videoBitrate) -> \(newVideoBitrate)")
        stream.videoSettings[.bitrate] = newVideoBitrate
    }
    
    func didPublishInsufficientBW(_ stream: RTMPStream, withConnection: RTMPConnection) {
        guard let videoBitrate = stream.videoSettings[.bitrate] as? UInt32 else { return }
        
        var newVideoBitrate = UInt32(videoBitrate / 2)
        if newVideoBitrate < minBitrate {
            newVideoBitrate = minBitrate
        }
        print("didPublishInsufficientBW update: \(videoBitrate) -> \(newVideoBitrate)")
        stream.videoSettings[.bitrate] = newVideoBitrate
    }
    
    func clear() {
    }
}
