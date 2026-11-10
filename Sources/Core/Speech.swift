//
//  Speech.swift
//  RootWord · 词根单词
//
//  发音（系统 TTS）：AVSpeechSynthesizer，零三方依赖。
//
//  行为约定（文档 5.4 与 9.10）：
//    · 不主动改动 AVAudioSession 类别 → 保持系统默认（soloAmbient），因此遵守静音拨片：
//      静音时不发声，但图标仍给出反馈，避免"课堂突然发声"。
//    · 不自动朗读（autoPlayAudio 默认 false）。
//    · 发音中图标切换为声波动画；同一时刻只允许一个朗读，重复点击先停后读。
//

import AVFoundation

@MainActor
final class SpeechService: NSObject, ObservableObject {

    static let shared = SpeechService()

    /// 当前正在朗读的文本（nil 表示空闲），用于喇叭图标动画
    @Published private(set) var speakingText: String?

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, accent: String) {
        guard !text.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: accent) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.44          // 略慢于默认，便于初中生跟读
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.05
        speakingText = text
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        speakingText = nil
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil }
    }
}
