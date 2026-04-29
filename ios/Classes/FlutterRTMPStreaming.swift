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
    private var eventSink: FlutterEventSink?
    private var isStreaming: Bool = false
    private let myDelegate = MyRTMPStreamQoSDelagate()

    @objc
    public init(sink: @escaping FlutterEventSink) {
        eventSink = sink
    }
    
    @objc
    public func open(url: String, width: Int, height: Int, bitrate: Int) {
        print("[RIGATTA-SWIFT] TEST 1: Kun RTMPConnection uten RTMPStream")
        
        // Test 1: Kun connection, ingen stream
        self.url = url
        print("[RIGATTA-SWIFT] TEST 1: Lager RTMPConnection...")
        
        // Legg til status handler for å se events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rtmpStatusHandler(_:)),
            name: NSNotification.Name.RTMPConnection,
            object: nil
        )
        
        print("[RIGATTA-SWIFT] TEST 1: Klargjør for connect...")
        self.retries = 0
        
        // Test connection uten stream
        DispatchQueue.main.async {
            print("[RIGATTA-SWIFT] TEST 1: Starter connect til: \(self.url ?? "NIL")")
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
            self.isStreaming = true
            print("[RIGATTA-SWIFT] rtmpStatusHandler: publish() completed successfully, isStreaming=true")
            retries = 0
            DispatchQueue.main.async { 
            guard let sink = self.eventSink else { return }
            sink(["event" : "rtmp_connected", "errorDescription" : ""]) 
        }
            break
        case RTMPConnection.Code.connectFailed.rawValue, RTMPConnection.Code.connectClosed.rawValue:
            guard retries <= 3 else {
                DispatchQueue.main.async { 
                guard let sink = self.eventSink else { return }
                sink(["event" : "error", "errorDescription" : "connection failed " + e.type.rawValue]) 
            }
                return
            }
            retries += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + pow(2.0, Double(retries))) {
                self.rtmpConnection.connect(self.url!)
            }
            DispatchQueue.main.async { 
                guard let sink = self.eventSink else { return }
                sink(["event" : "rtmp_retry", "errorDescription" : "connection failed " + e.type.rawValue]) 
            }
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
            DispatchQueue.main.async { 
                guard let sink = self.eventSink else { return }
                sink(["event" : "rtmp_stopped", "errorDescription" : "rtmp disconnected"]) 
            }
            return
        }
        retries += 1
        DispatchQueue.global().asyncAfter(deadline: .now() + pow(2.0, Double(retries))) {
            self.rtmpConnection.connect(self.url!)
        }
        DispatchQueue.main.async { 
            guard let sink = self.eventSink else { return }
            sink(["event" : "rtmp_retry", "errorDescription" : "rtmp disconnected"]) 
        }
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
        rtmpStream.appendSampleBuffer(buffer, withType: .video)
    }
    
    @objc
    public func addAudioData(buffer: CMSampleBuffer) {
        rtmpStream.appendSampleBuffer(buffer, withType: .audio)
    }
    
    @objc
    public func close() {
        isStreaming = false
        print("[RIGATTA-SWIFT] close(): stopping streaming, isStreaming=false")
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
