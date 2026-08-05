import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

private let lockedSimulatorName = "Xabber Chat Fixed Live QA iPhone 16 Pro"
private let readyRecord = Data("READY\n".utf8)

private enum RecorderFailure: String, Error {
    case captureStart = "capture-start"
    case captureStop = "capture-stop"
    case captureStopTimeout = "capture-stop-timeout"
    case invalidArguments = "invalid-arguments"
    case invalidOutput = "invalid-output"
    case recordingOutputAttachment = "recording-output-attachment"
    case recordingOutputFailure = "recording-output-failure"
    case shareableContentUnavailable = "shareable-content-unavailable"
    case stopBeforeStart = "stop-before-start"
    case streamStop = "stream-stop"
    case unknown
    case windowIdentityMismatch = "window-identity-mismatch"
    case windowNotFound = "window-not-found"
}

private func exitWithFailure(_ failure: RecorderFailure) -> Never {
    let record = Data("RECORDER_ERROR:\(failure.rawValue)\n".utf8)
    FileHandle.standardError.write(record)
    Foundation.exit(EXIT_FAILURE)
}

@available(macOS 15.0, *)
private final class WindowRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private let windowID: CGWindowID
    private let outputURL: URL
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var interruptSource: DispatchSourceSignal?
    private var terminateSource: DispatchSourceSignal?
    private var stopRequested = false
    private var finished = false
    private var readinessEmitted = false

    init(windowID: CGWindowID, outputURL: URL) {
        self.windowID = windowID
        self.outputURL = outputURL
    }

    func run() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        interruptSource = makeSignalSource(SIGINT)
        terminateSource = makeSignalSource(SIGTERM)
        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) { [weak self] content, error in
            guard let self else { return }
            guard error == nil, let content else {
                self.fail(.shareableContentUnavailable)
            }
            let matchingWindows = content.windows.filter { $0.windowID == self.windowID }
            guard matchingWindows.count == 1, let window = matchingWindows.first else {
                self.fail(.windowNotFound)
            }
            guard
                window.owningApplication?.applicationName == "Simulator",
                window.title?.contains(lockedSimulatorName) == true,
                window.windowLayer == 0,
                window.isOnScreen
            else {
                self.fail(.windowIdentityMismatch)
            }
            DispatchQueue.main.async { [weak self] in
                self?.start(window: window)
            }
        }
        NSApplication.shared.run()
    }

    private func makeSignalSource(_ signalNumber: Int32) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { [weak self] in
            self?.stop()
        }
        source.resume()
        return source
    }

    private func start(window: SCWindow) {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            fail(.invalidOutput)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width.rounded()))
        configuration.height = max(1, Int(window.frame.height.rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 8
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.videoCodecType = .h264
        recordingConfiguration.outputFileType = .mov

        let output = SCRecordingOutput(
            configuration: recordingConfiguration,
            delegate: self
        )
        let candidateStream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration,
            delegate: self
        )
        do {
            try candidateStream.addRecordingOutput(output)
        } catch {
            fail(.recordingOutputAttachment)
        }
        recordingOutput = output
        stream = candidateStream
        candidateStream.startCapture { [weak self] error in
            if error != nil {
                self?.fail(.captureStart)
            }
        }
    }

    private func stop() {
        guard !stopRequested, !finished else { return }
        stopRequested = true
        guard let stream else {
            fail(.stopBeforeStart)
        }
        stream.stopCapture { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.fail(.captureStop)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.finished else { return }
                self.fail(.captureStopTimeout)
            }
        }
    }

    private func fail(_ failure: RecorderFailure) -> Never {
        if readinessEmitted {
            Foundation.exit(EXIT_FAILURE)
        }
        exitWithFailure(failure)
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        guard !stopRequested, !finished else { return }
        readinessEmitted = true
        FileHandle.standardOutput.write(readyRecord)
    }

    func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        fail(.recordingOutputFailure)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        guard !finished else { return }
        finished = true
        Foundation.exit(EXIT_SUCCESS)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        if !stopRequested {
            fail(.streamStop)
        }
    }
}

private func parseArguments() throws -> (CGWindowID, URL) {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard
        arguments.count == 4,
        arguments[0] == "--window-id",
        let parsedWindowID = UInt32(arguments[1]),
        parsedWindowID > 0,
        arguments[2] == "--output"
    else {
        throw RecorderFailure.invalidArguments
    }
    let outputURL = URL(fileURLWithPath: arguments[3])
    guard
        outputURL.path.hasPrefix("/"),
        outputURL.pathExtension.lowercased() == "mov",
        !FileManager.default.fileExists(atPath: outputURL.path),
        FileManager.default.fileExists(atPath: outputURL.deletingLastPathComponent().path)
    else {
        throw RecorderFailure.invalidOutput
    }
    return (CGWindowID(parsedWindowID), outputURL)
}

guard #available(macOS 15.0, *) else {
    Foundation.exit(EXIT_FAILURE)
}

do {
    let (windowID, outputURL) = try parseArguments()
    _ = NSApplication.shared
    WindowRecorder(windowID: windowID, outputURL: outputURL).run()
} catch let failure as RecorderFailure {
    exitWithFailure(failure)
} catch {
    exitWithFailure(.unknown)
}
