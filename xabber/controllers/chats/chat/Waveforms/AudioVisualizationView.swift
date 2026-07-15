//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 3 of the License.
//

import UIKit

enum ChatWaveformRevision {
    static func make(identity: String, levels: [Float]) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for level in levels {
            hash ^= UInt64(level.bitPattern)
            hash &*= 1_099_511_628_211
        }
        return "\(identity)-\(levels.count)-\(hash)"
    }
}

struct ChatWaveformRenderMetrics: Equatable {
    let sampleNormalizationCount: Int
    let staticPathBuildCount: Int
    let progressMutationCount: Int
}

enum ChatWaveformRenderInstrumentation {
    private(set) static var sampleNormalizationCount = 0
    private(set) static var staticPathBuildCount = 0
    private(set) static var progressMutationCount = 0

    static var snapshot: ChatWaveformRenderMetrics {
        ChatWaveformRenderMetrics(
            sampleNormalizationCount: sampleNormalizationCount,
            staticPathBuildCount: staticPathBuildCount,
            progressMutationCount: progressMutationCount
        )
    }

    static func resetForTests() {
        sampleNormalizationCount = 0
        staticPathBuildCount = 0
        progressMutationCount = 0
        ChatWaveformStaticArtifactCache.shared.removeAll()
    }

    static func simulateMemoryWarningForTests() {
        handleMemoryWarning()
    }

    static func handleMemoryWarning() {
        ChatWaveformStaticArtifactCache.shared.removeAll()
    }

    fileprivate static func recordNormalization() {
        sampleNormalizationCount += 1
    }

    fileprivate static func recordPathBuild() {
        staticPathBuildCount += 1
    }

    fileprivate static func recordProgressMutation() {
        progressMutationCount += 1
    }
}

private struct ChatWaveformStaticArtifactKey: Hashable {
    let revision: String
    let widthPixels: Int
    let heightPixels: Int
    let barWidthPixels: Int
    let spacingPixels: Int
    let cornerRadiusPixels: Int
    let type: AudioVisualizationView.AudioVisualizationType
}

private final class ChatWaveformStaticArtifactKeyBox: NSObject {
    let value: ChatWaveformStaticArtifactKey

    init(_ value: ChatWaveformStaticArtifactKey) {
        self.value = value
    }

    override var hash: Int {
        value.hashValue
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? ChatWaveformStaticArtifactKeyBox)?.value == value
    }
}

private final class ChatWaveformStaticArtifact {
    let path: CGPath

    init(path: CGPath) {
        self.path = path
    }
}

private final class ChatWaveformStaticArtifactCache {
    static let shared = ChatWaveformStaticArtifactCache()

    private let storage: NSCache<ChatWaveformStaticArtifactKeyBox, ChatWaveformStaticArtifact> = {
        let cache = NSCache<ChatWaveformStaticArtifactKeyBox, ChatWaveformStaticArtifact>()
        cache.countLimit = ChatPerformanceResourceBudgets.waveformArtifactCount
        return cache
    }()
    private init() {}

    func artifact(
        for key: ChatWaveformStaticArtifactKey,
        levels: [Float],
        size: CGSize,
        barWidth: CGFloat,
        spacing: CGFloat,
        cornerRadius: CGFloat
    ) -> ChatWaveformStaticArtifact {
        let boxedKey = ChatWaveformStaticArtifactKeyBox(key)
        if let cached = storage.object(forKey: boxedKey) {
            return cached
        }

        ChatWaveformRenderInstrumentation.recordNormalization()
        let samples = Self.normalizedSamples(
            levels,
            targetCount: max(1, Int(size.width / max(barWidth + spacing, 1)))
        )
        ChatWaveformRenderInstrumentation.recordPathBuild()
        let path = Self.makePath(
            samples: samples,
            size: size,
            barWidth: barWidth,
            spacing: spacing,
            cornerRadius: cornerRadius,
            type: key.type
        )
        let artifact = ChatWaveformStaticArtifact(path: path)
        storage.setObject(artifact, forKey: boxedKey)
        return artifact
    }

    func removeAll() {
        storage.removeAllObjects()
    }

    private static func normalizedSamples(_ levels: [Float], targetCount: Int) -> [CGFloat] {
        guard !levels.isEmpty, targetCount > 0 else { return [] }
        let clamped = levels.map { CGFloat(min(max($0, 0), 1)) }
        if clamped.count == targetCount {
            return clamped
        }

        return (0..<targetCount).map { targetIndex in
            let lower = CGFloat(targetIndex) * CGFloat(clamped.count) / CGFloat(targetCount)
            let upper = CGFloat(targetIndex + 1) * CGFloat(clamped.count) / CGFloat(targetCount)
            let firstIndex = min(Int(floor(lower)), clamped.count - 1)
            let lastIndex = min(max(Int(ceil(upper)) - 1, firstIndex), clamped.count - 1)

            if firstIndex == lastIndex {
                let nextIndex = min(firstIndex + 1, clamped.count - 1)
                let fraction = lower - floor(lower)
                return clamped[firstIndex] + ((clamped[nextIndex] - clamped[firstIndex]) * fraction)
            }

            let slice = clamped[firstIndex...lastIndex]
            return slice.reduce(0, +) / CGFloat(slice.count)
        }
    }

    private static func makePath(
        samples: [CGFloat],
        size: CGSize,
        barWidth: CGFloat,
        spacing: CGFloat,
        cornerRadius: CGFloat,
        type: AudioVisualizationView.AudioVisualizationType
    ) -> CGPath {
        let path = CGMutablePath()
        let centerY = size.height / 2
        let maximumHeight = max(size.height - 2, 1)

        for (index, sample) in samples.enumerated() {
            let height = max(2, sample * maximumHeight)
            let originY: CGFloat
            let renderedHeight: CGFloat
            switch type {
            case .top:
                originY = centerY - height
                renderedHeight = height
            case .bottom:
                originY = centerY
                renderedHeight = height
            case .both:
                originY = centerY - height / 2
                renderedHeight = height
            }
            let rect = CGRect(
                x: CGFloat(index) * (barWidth + spacing),
                y: originY,
                width: barWidth,
                height: renderedHeight
            )
            path.addPath(
                UIBezierPath(
                    roundedRect: rect,
                    cornerRadius: min(cornerRadius, min(barWidth / 2, renderedHeight / 2))
                ).cgPath
            )
        }
        return path
    }
}

public final class AudioVisualizationView: UIView {
    public enum AudioVisualizationMode {
        case read
        case write
    }

    public enum AudioVisualizationType: Hashable {
        case top
        case bottom
        case both
    }

    @IBInspectable public var meteringLevelBarWidth: CGFloat = 3 {
        didSet { invalidateStaticArtifact() }
    }

    @IBInspectable public var meteringLevelBarInterItem: CGFloat = 2 {
        didSet { invalidateStaticArtifact() }
    }

    @IBInspectable public var meteringLevelBarCornerRadius: CGFloat = 2 {
        didSet { invalidateStaticArtifact() }
    }

    public var audioVisualizationType: AudioVisualizationType = .both {
        didSet { invalidateStaticArtifact() }
    }

    public var audioVisualizationMode: AudioVisualizationMode = .read

    public var barBackgroundFillColor: UIColor? {
        didSet { updateLayerColors() }
    }

    public var progressBarMiddleOffset: CGFloat?
    public var progressBarLineHeight: CGFloat = 0
    public var audioVisualizationTimeInterval: TimeInterval = 0.05
    public var startFrom: TimeInterval = 0
    public var drawCallback: (() -> Void)?

    public static var audioVisualizationDefaultGradientStartColor: UIColor {
        UIColor(red: 61 / 255, green: 20 / 255, blue: 117 / 255, alpha: 1)
    }

    public static var audioVisualizationDefaultGradientEndColor: UIColor {
        UIColor(red: 166 / 255, green: 150 / 255, blue: 225 / 255, alpha: 1)
    }

    @IBInspectable public var gradientStartColor: UIColor = AudioVisualizationView.audioVisualizationDefaultGradientStartColor {
        didSet { updateLayerColors() }
    }

    @IBInspectable public var gradientEndColor: UIColor = AudioVisualizationView.audioVisualizationDefaultGradientEndColor {
        didSet { updateLayerColors() }
    }

    public var currentGradientPercentage: Float? {
        didSet {
            guard oldValue != currentGradientPercentage else { return }
            applyProgressLayer(recordMetric: true)
        }
    }

    public var meteringLevels: [Float]? {
        didSet {
            let levels = meteringLevels ?? []
            configureStaticWaveform(
                levels: levels,
                revision: ChatWaveformRevision.make(identity: "legacy", levels: levels)
            )
        }
    }

    public private(set) var playChronometer: Chronometer?
    public private(set) var isPlayed = false

    var activeClockCount: Int {
        playChronometer == nil ? 0 : 1
    }

    var debugProgressMaskFrame: CGRect {
        progressMaskLayer.frame
    }

    private let backgroundBarsLayer = CAShapeLayer()
    private let progressContainerLayer = CALayer()
    private let progressGradientLayer = CAGradientLayer()
    private let progressBarsMaskLayer = CAShapeLayer()
    private let progressMaskLayer = CALayer()
    private var sourceLevels: [Float] = []
    private var sourceRevision = ""
    private var lastArtifactKey: ChatWaveformStaticArtifactKey?
    private var recordingLevels: [Float] = []
    private var recordingRevision = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        installStaticArtifactIfNeeded()
        updateLayerFrames()
    }

    public func configureStaticWaveform(levels: [Float], revision: String) {
        guard sourceRevision != revision else {
            installStaticArtifactIfNeeded()
            return
        }
        sourceLevels = levels
        sourceRevision = revision
        lastArtifactKey = nil
        installStaticArtifactIfNeeded()
    }

    public func setProgress(_ progress: Float?) {
        currentGradientPercentage = progress
    }

    public func reset() {
        pause()
        startFrom = 0
        setProgress(nil)
    }

    public func add(meteringLevel: Float) {
        guard audioVisualizationMode == .write else {
            assertionFailure("Trying to populate audio visualization view in read mode")
            return
        }
        recordingLevels.append(meteringLevel)
        recordingRevision += 1
        configureStaticWaveform(
            levels: recordingLevels,
            revision: "recording-\(recordingRevision)"
        )
    }

    public func scaleSoundDataToFitScreen() -> [Float] {
        scaleOuterArrayToFitScreen(recordingLevels)
    }

    public func scaleOuterArrayToFitScreen(_ array: [Float]) -> [Float] {
        let count = max(1, Int(bounds.width / max(meteringLevelBarWidth + meteringLevelBarInterItem, 1)))
        return Self.resampled(array, targetCount: count)
    }

    public func play(for duration: TimeInterval) {
        guard audioVisualizationMode == .read, !sourceLevels.isEmpty else { return }
        playChronometer?.pause()
        let remainingDuration = max(duration, 0)
        let totalDuration = max(max(startFrom + remainingDuration, remainingDuration), 0.001)
        let chronometer = Chronometer(withTimeInterval: audioVisualizationTimeInterval)
        playChronometer = chronometer
        isPlayed = true
        chronometer.timerDidUpdate = { [weak self, weak chronometer] elapsed in
            guard let self, self.playChronometer === chronometer else { return }
            if elapsed >= remainingDuration {
                self.stop()
                return
            }
            self.setProgress(Float((self.startFrom + elapsed) / totalDuration))
            self.drawCallback?()
        }
        chronometer.start(shouldFire: false)
    }

    public func pause() {
        isPlayed = false
        playChronometer?.pause()
        playChronometer = nil
    }

    public func stop() {
        let chronometer = playChronometer
        playChronometer = nil
        isPlayed = false
        chronometer?.stop()
        setProgress(0)
    }

    private func setupLayers() {
        isOpaque = false
        layer.addSublayer(backgroundBarsLayer)
        layer.addSublayer(progressContainerLayer)
        progressContainerLayer.addSublayer(progressGradientLayer)
        progressGradientLayer.mask = progressBarsMaskLayer
        progressMaskLayer.backgroundColor = UIColor.black.cgColor
        progressContainerLayer.mask = progressMaskLayer
        updateLayerColors()
        updateLayerFrames()
    }

    private func invalidateStaticArtifact() {
        lastArtifactKey = nil
        installStaticArtifactIfNeeded()
    }

    private func installStaticArtifactIfNeeded() {
        guard bounds.width > 0, bounds.height > 0, !sourceLevels.isEmpty else {
            if sourceLevels.isEmpty {
                backgroundBarsLayer.path = nil
                progressBarsMaskLayer.path = nil
                lastArtifactKey = nil
            }
            return
        }
        let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1)
        let key = ChatWaveformStaticArtifactKey(
            revision: sourceRevision,
            widthPixels: Int((bounds.width * scale).rounded()),
            heightPixels: Int((bounds.height * scale).rounded()),
            barWidthPixels: Int((meteringLevelBarWidth * scale).rounded()),
            spacingPixels: Int((meteringLevelBarInterItem * scale).rounded()),
            cornerRadiusPixels: Int((meteringLevelBarCornerRadius * scale).rounded()),
            type: audioVisualizationType
        )
        guard key != lastArtifactKey else { return }
        let artifact = ChatWaveformStaticArtifactCache.shared.artifact(
            for: key,
            levels: sourceLevels,
            size: bounds.size,
            barWidth: meteringLevelBarWidth,
            spacing: meteringLevelBarInterItem,
            cornerRadius: meteringLevelBarCornerRadius
        )
        withoutLayerAnimations {
            backgroundBarsLayer.path = artifact.path
            progressBarsMaskLayer.path = artifact.path
        }
        lastArtifactKey = key
    }

    private func updateLayerFrames() {
        withoutLayerAnimations {
            backgroundBarsLayer.frame = bounds
            progressContainerLayer.frame = bounds
            progressGradientLayer.frame = bounds
            progressBarsMaskLayer.frame = bounds
            applyProgressLayer(recordMetric: false)
        }
    }

    private func updateLayerColors() {
        withoutLayerAnimations {
            backgroundBarsLayer.fillColor = (barBackgroundFillColor ?? gradientEndColor).cgColor
            progressGradientLayer.colors = [gradientStartColor.cgColor, gradientEndColor.cgColor]
            progressGradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
            progressGradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        }
    }

    private func applyProgressLayer(recordMetric: Bool) {
        let progress = CGFloat(min(max(currentGradientPercentage ?? 1, 0), 1))
        withoutLayerAnimations {
            progressMaskLayer.frame = CGRect(
                x: 0,
                y: 0,
                width: bounds.width * progress,
                height: bounds.height
            )
        }
        if recordMetric {
            ChatWaveformRenderInstrumentation.recordProgressMutation()
        }
    }

    private func withoutLayerAnimations(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updates()
        CATransaction.commit()
    }

    private static func resampled(_ levels: [Float], targetCount: Int) -> [Float] {
        guard !levels.isEmpty, targetCount > 0 else { return [] }
        if levels.count == targetCount { return levels }
        return (0..<targetCount).map { index in
            let position = Float(index) * Float(max(levels.count - 1, 0)) / Float(max(targetCount - 1, 1))
            let lower = min(Int(floor(position)), levels.count - 1)
            let upper = min(lower + 1, levels.count - 1)
            let fraction = position - Float(lower)
            return levels[lower] + ((levels[upper] - levels[lower]) * fraction)
        }
    }
}
