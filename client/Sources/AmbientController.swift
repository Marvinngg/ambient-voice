import CoreAudio
import Foundation

/// G1: 声音门控 — ambient 模式
/// 使用 CoreAudio HAL VAD（硬件级语音检测）替代手动热键触发
/// 检测到语音开始 → 自动启动录音，语音结束 + settle delay → 自动停止
///
/// 与热键模式互斥：ambient 开启时热键仍可用（手动覆盖）
@MainActor
final class AmbientController {
    static let shared = AmbientController()

    private(set) var isEnabled = false
    private var deviceID: AudioDeviceID = 0
    private var isSpeaking = false
    private var settleWork: DispatchWorkItem?

    /// 语音结束后的沉淀延迟（防止句间停顿误判为结束）
    var settleDelay: TimeInterval = 0.8

    /// 最短语音时长（过滤咳嗽/噪声）
    var minimumDuration: TimeInterval = 0.5
    private var speechStartTime: Date?

    /// 回调
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    func start() {
        guard !isEnabled else { return }

        // 获取默认输入设备
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &size, &devID
        )
        guard status == noErr, devID != 0 else {
            Logger.log("Ambient", "Failed to get default input device: \(status)")
            return
        }
        self.deviceID = devID

        // 启用 HAL VAD
        var enable: UInt32 = 1
        var vadEnableAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionEnable,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        let enableStatus = AudioObjectSetPropertyData(
            devID, &vadEnableAddr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &enable
        )
        guard enableStatus == noErr else {
            Logger.log("Ambient", "HAL VAD not supported on this device: \(enableStatus)")
            return
        }

        // 监听 VAD 状态变化
        var vadStateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionState,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        let listenerStatus = AudioObjectAddPropertyListenerBlock(
            devID, &vadStateAddr,
            DispatchQueue.global(qos: .userInteractive)
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleVADChange()
            }
        }

        guard listenerStatus == noErr else {
            Logger.log("Ambient", "Failed to add VAD listener: \(listenerStatus)")
            return
        }

        isEnabled = true
        Logger.log("Ambient", "HAL VAD enabled (device=\(devID), settle=\(settleDelay)s)")
    }

    func stop() {
        guard isEnabled else { return }

        // 关闭 VAD
        var disable: UInt32 = 0
        var vadEnableAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionEnable,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            deviceID, &vadEnableAddr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &disable
        )

        settleWork?.cancel()
        settleWork = nil
        isSpeaking = false
        isEnabled = false
        Logger.log("Ambient", "HAL VAD disabled")
    }

    // MARK: - VAD 状态变化

    private func handleVADChange() {
        var state: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionState,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &state)

        let speaking = state != 0

        if speaking && !isSpeaking {
            // 语音开始
            isSpeaking = true
            speechStartTime = Date()
            settleWork?.cancel()
            Logger.log("Ambient", "Voice detected")
            onSpeechStart?()

        } else if !speaking && isSpeaking {
            // 语音可能结束 — 启动 settle 延迟
            settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isSpeaking else { return }
                self.isSpeaking = false

                // 检查最短时长
                if let start = self.speechStartTime,
                   Date().timeIntervalSince(start) < self.minimumDuration {
                    Logger.log("Ambient", "Too short, ignored")
                    return
                }

                Logger.log("Ambient", "Voice ended (after \(self.settleDelay)s settle)")
                self.onSpeechEnd?()
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
        }
    }
}
