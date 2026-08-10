// Low-latency microphone recorder for the Hammerspoon dictation hotkey.
//
// Replaces `ffmpeg -f avfoundation`, which needed 1.4-3.5s to open the input device (measured).
// With a 2-4s push-to-talk hold that swallowed most of each sentence, so Whisper only ever saw
// a fragment of what was said. CoreAudio via AVAudioRecorder opens the same mic far faster.
//
// Usage:  dictation-recorder <output.wav>
// Records 16 kHz mono 16-bit PCM (what Whisper wants) until SIGTERM, then finalizes the WAV.

import AVFoundation
import Foundation

let t0 = Date()
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/hs-dictation.wav"
let url = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: url)

let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
]

guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
    FileHandle.standardError.write("failed to create recorder\n".data(using: .utf8)!)
    exit(1)
}

let tCreated = Date()
recorder.prepareToRecord()
let tPrepared = Date()

guard recorder.record() else {
    FileHandle.standardError.write("record() refused - microphone permission?\n".data(using: .utf8)!)
    exit(2)
}
let tRecording = Date()

// Tell the caller the mic is genuinely capturing now, so it can cue the user to start talking.
// Without this the UI says "recording" ~0.5s before any audio actually lands on disk, and the
// first word of every sentence gets clipped - the exact failure this whole recorder exists to fix.
FileHandle.standardOutput.write("READY\n".data(using: .utf8)!)

if ProcessInfo.processInfo.environment["DICTATION_TIMING"] != nil {
    let ms = { (a: Date, b: Date) in String(format: "%.0fms", b.timeIntervalSince(a) * 1000) }
    FileHandle.standardError.write(
        "init=\(ms(t0, tCreated)) prepare=\(ms(tCreated, tPrepared)) record=\(ms(tPrepared, tRecording)) total=\(ms(t0, tRecording))\n"
            .data(using: .utf8)!)
}

// SIG_IGN + DispatchSource so the handler can touch `recorder` (a C signal handler cannot).
var signalSources: [DispatchSourceSignal] = []
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
for sig in [SIGTERM, SIGINT] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        recorder.stop()   // writes the correct WAV header/length
        exit(0)
    }
    src.resume()
    signalSources.append(src)   // retain, or ARC frees the source and the handler never fires
}

RunLoop.main.run()
