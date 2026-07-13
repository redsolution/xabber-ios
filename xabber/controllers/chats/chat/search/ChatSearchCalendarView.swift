//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import UIKit

enum ChatSearchCalendarLayout {
    static let maximumContentWidth: CGFloat = 390
    static let topCornerRadius: CGFloat = 24
    static let headerHeight: CGFloat = 60
    static let monthNavigationHeight: CGFloat = 52
    static let weekdayHeight: CGFloat = 28
    static let dayHeight: CGFloat = 44
    static let pickerHeight: CGFloat = 220
    static let doneHeight: CGFloat = 52
    static let doneHorizontalInset: CGFloat = 30
    static let bottomInset: CGFloat = 12
    static let contentSpacing: CGFloat = 16

    struct Frames: Equatable {
        let surface: CGRect
        let close: CGRect
        let title: CGRect
        let month: CGRect
        let previousMonth: CGRect
        let nextMonth: CGRect
        let weekdays: CGRect
        let grid: CGRect
        let picker: CGRect
        let done: CGRect
        let sheetHeight: CGFloat
    }

    static func frames(
        in bounds: CGRect,
        rowCount: Int,
        isMonthYearPickerPresented: Bool,
        safeAreaInsets: UIEdgeInsets,
        layoutDirection: UIUserInterfaceLayoutDirection = .leftToRight
    ) -> Frames {
        let contentWidth = min(maximumContentWidth, max(0, bounds.width))
        let contentX = bounds.minX + max(0, (bounds.width - contentWidth) / 2)
        let controlSize: CGFloat = 44
        let close = CGRect(x: contentX + 16, y: bounds.minY + 8, width: controlSize, height: controlSize)
        let title = CGRect(
            x: contentX + 60,
            y: bounds.minY,
            width: max(0, contentWidth - 120),
            height: headerHeight
        )
        let navigationY = bounds.minY + headerHeight
        let leadingControl = CGRect(x: contentX + 16, y: navigationY + 4, width: controlSize, height: controlSize)
        let trailingControl = CGRect(
            x: contentX + contentWidth - 60,
            y: navigationY + 4,
            width: controlSize,
            height: controlSize
        )
        let previousMonth = layoutDirection == .rightToLeft ? trailingControl : leadingControl
        let nextMonth = layoutDirection == .rightToLeft ? leadingControl : trailingControl
        let month = CGRect(
            x: contentX + 60,
            y: navigationY + 4,
            width: max(0, contentWidth - 120),
            height: controlSize
        )
        let weekdayY = navigationY + monthNavigationHeight
        let weekdays = CGRect(x: contentX, y: weekdayY, width: contentWidth, height: weekdayHeight)
        let resolvedRows = min(6, max(4, rowCount))
        let grid = CGRect(
            x: contentX,
            y: weekdays.maxY,
            width: contentWidth,
            height: CGFloat(resolvedRows) * dayHeight
        )
        let picker = CGRect(
            x: contentX + 16,
            y: weekdayY,
            width: max(0, contentWidth - 32),
            height: pickerHeight
        )
        let contentBottom = isMonthYearPickerPresented ? picker.maxY : grid.maxY
        let done = CGRect(
            x: contentX + doneHorizontalInset,
            y: contentBottom + contentSpacing,
            width: max(0, contentWidth - doneHorizontalInset * 2),
            height: doneHeight
        )
        let sheetHeight = done.maxY - bounds.minY + bottomInset + max(0, safeAreaInsets.bottom)
        let surface = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: min(max(0, bounds.height), sheetHeight)
        )
        return Frames(
            surface: surface,
            close: close,
            title: title,
            month: month,
            previousMonth: previousMonth,
            nextMonth: nextMonth,
            weekdays: weekdays,
            grid: grid,
            picker: picker,
            done: done,
            sheetHeight: sheetHeight
        )
    }
}

final class ChatSearchCalendarView: UIView {
    struct MonthTransitionRecord: Equatable {
        let duration: TimeInterval
        let mode: ChatSearchAnimationSpec.MonthSwipe.Mode
        let travelDirection: ChatSearchAnimationSpec.HorizontalTravelDirection
        let snapshot: ChatSearchCalendarModel.Snapshot
    }

    static let accessibilityIdentifier = "chat_search_calendar"
    static let closeAccessibilityIdentifier = "chat_search_calendar_close"
    static let monthAccessibilityIdentifier = "chat_search_calendar_month"
    static let previousAccessibilityIdentifier = "chat_search_calendar_previous_month"
    static let nextAccessibilityIdentifier = "chat_search_calendar_next_month"
    static let doneAccessibilityIdentifier = "chat_search_calendar_done"

    var onClose: (() -> Void)?
    var onPreviousMonth: (() -> Void)?
    var onNextMonth: (() -> Void)?
    var onToggleMonthYearPicker: (() -> Void)?
    var onSelectDay: ((ChatSearchCalendarModel.DaySlot.ID) -> Void)?
    var onDone: (() -> Void)?
    var onSelectMonthYear: ((Int, Int) -> Void)?
    var onDismissMonthYearPicker: (() -> Void)?
    var onApplyMonthYearPicker: (() -> Void)?
    var onSwipeMonth: ((ChatSearchCalendarModel.VisualSwipeDirection) -> Void)?

    private(set) var renderedSnapshot: ChatSearchCalendarModel.Snapshot?
    private(set) var lastMonthTransition: MonthTransitionRecord?
    private(set) var yearPickerYears: [Int] = []

    let surfaceView: UIVisualEffectView
    let titleLabel = UILabel()
    let closeButton = UIButton(type: .system)
    let monthButton = UIButton(type: .system)
    let previousButton = UIButton(type: .system)
    let nextButton = UIButton(type: .system)
    let weekdayContainerView = UIView()
    private(set) var weekdayLabels: [UILabel] = []
    let collectionView: UICollectionView
    let monthYearPickerContainerView = UIView()
    let monthPicker = UIPickerView()
    let yearPicker = UIPickerView()
    let pickerCloseButton = UIButton(type: .system)
    let pickerApplyButton = UIButton(type: .system)
    let doneButton = UIButton(type: .system)

    private let animationSpec: ChatSearchAnimationSpec
    private var runningMonthAnimator: UIViewPropertyAnimator?
    private weak var outgoingMonthSnapshotView: UIView?

    override var intrinsicContentSize: CGSize {
        guard let renderedSnapshot else {
            return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
        let height = ChatSearchCalendarLayout.frames(
            in: CGRect(x: 0, y: 0, width: max(bounds.width, ChatSearchCalendarLayout.maximumContentWidth), height: 1_000),
            rowCount: renderedSnapshot.rowCount,
            isMonthYearPickerPresented: renderedSnapshot.isMonthYearPickerPresented,
            safeAreaInsets: safeAreaInsets
        ).sheetHeight
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override var semanticContentAttribute: UISemanticContentAttribute {
        didSet {
            synchronizeSemanticDirection()
            setNeedsLayout()
        }
    }

    init(
        frame: CGRect,
        snapshot: ChatSearchCalendarModel.Snapshot,
        animationSpec: ChatSearchAnimationSpec = .production,
        prefersNativeGlass: Bool = true
    ) {
        self.animationSpec = animationSpec
        surfaceView = UIVisualEffectView(
            effect: NativeGlassBarStyle.makeEffect(
                role: .sheet,
                interactive: false,
                prefersNativeGlass: prefersNativeGlass
            )
        )
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        setup(prefersNativeGlass: prefersNativeGlass)
        render(snapshot: snapshot, animated: false)
    }

    required init?(coder: NSCoder) {
        animationSpec = ChatSearchAnimationSpec.production.resolved(
            for: .init(
                reduceMotion: UIAccessibility.isReduceMotionEnabled,
                reduceTransparency: UIAccessibility.isReduceTransparencyEnabled
            )
        )
        surfaceView = UIVisualEffectView(
            effect: NativeGlassBarStyle.makeEffect(role: .sheet, interactive: false)
        )
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(coder: coder)
        setup(prefersNativeGlass: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let renderedSnapshot else {
            surfaceView.frame = bounds
            return
        }
        let direction = resolvedLayoutDirection
        let frames = ChatSearchCalendarLayout.frames(
            in: bounds,
            rowCount: renderedSnapshot.rowCount,
            isMonthYearPickerPresented: renderedSnapshot.isMonthYearPickerPresented,
            safeAreaInsets: safeAreaInsets,
            layoutDirection: direction
        )
        surfaceView.frame = frames.surface
        closeButton.frame = frames.close
        titleLabel.frame = frames.title
        monthButton.frame = frames.month
        previousButton.frame = frames.previousMonth
        nextButton.frame = frames.nextMonth
        weekdayContainerView.frame = frames.weekdays
        collectionView.frame = frames.grid
        monthYearPickerContainerView.frame = frames.picker
        doneButton.frame = frames.done

        layoutWeekdayLabels(direction: direction)
        layoutPickerControls(direction: direction)
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.itemSize = CGSize(
                width: collectionView.bounds.width / 7,
                height: ChatSearchCalendarLayout.dayHeight
            )
            layout.invalidateLayout()
        }
        doneButton.layer.cornerRadius = ChatSearchCalendarLayout.doneHeight / 2
        doneButton.layer.cornerCurve = .continuous
    }

    func render(
        snapshot: ChatSearchCalendarModel.Snapshot,
        animated: Bool,
        monthDirection: ChatSearchCalendarModel.MonthDirection? = nil
    ) {
        runningMonthAnimator?.stopAnimation(true)
        outgoingMonthSnapshotView?.removeFromSuperview()

        let oldSnapshotContainer = animated && monthDirection != nil ? makeMonthContentSnapshot() : nil
        renderedSnapshot = snapshot
        applySnapshot(snapshot)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        layoutIfNeeded()

        guard animated, let monthDirection else {
            lastMonthTransition = nil
            return
        }

        let semanticDirection: ChatSearchAnimationSpec.SemanticMonthDirection = monthDirection == .next ? .next : .previous
        let animationLayoutDirection: ChatSearchAnimationSpec.LayoutDirection = resolvedLayoutDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
        let travelDirection = animationSpec.monthSwipe.contentTravelDirection(
            for: semanticDirection,
            layoutDirection: animationLayoutDirection
        )
        lastMonthTransition = MonthTransitionRecord(
            duration: animationSpec.monthSwipe.timing.duration,
            mode: animationSpec.monthSwipe.mode,
            travelDirection: travelDirection,
            snapshot: snapshot
        )
        guard animationSpec.monthSwipe.timing.duration > 0, window != nil else {
            oldSnapshotContainer?.removeFromSuperview()
            return
        }
        animateMonthContent(from: oldSnapshotContainer, travelDirection: travelDirection)
    }

    func handleSwipe(_ direction: ChatSearchCalendarModel.VisualSwipeDirection) {
        onSwipeMonth?(direction)
    }

    private var resolvedLayoutDirection: UIUserInterfaceLayoutDirection {
        UIView.userInterfaceLayoutDirection(for: semanticContentAttribute)
    }

    private var monthContentViews: [UIView] {
        [monthButton, weekdayContainerView, collectionView, monthYearPickerContainerView]
    }

    private func setup(prefersNativeGlass: Bool) {
        accessibilityIdentifier = Self.accessibilityIdentifier
        backgroundColor = .clear

        NativeGlassBarStyle.applySurface(
            to: surfaceView,
            role: .sheet,
            cornerStyle: .fixed(ChatSearchCalendarLayout.topCornerRadius),
            interactive: false,
            prefersNativeGlass: prefersNativeGlass,
            maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        )
        surfaceView.contentView.backgroundColor = .systemBackground
        addSubview(surfaceView)

        titleLabel.text = "Search".localizeString(id: "search", arguments: [])
        titleLabel.textAlignment = .center
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        addSubview(titleLabel)

        configureIconButton(
            closeButton,
            identifier: Self.closeAccessibilityIdentifier,
            accessibilityLabel: "Close".localizeString(id: "close", arguments: []),
            systemImage: "xmark"
        )
        configureIconButton(
            previousButton,
            identifier: Self.previousAccessibilityIdentifier,
            accessibilityLabel: "Previous month".localizeString(id: "previous_month", arguments: []),
            systemImage: "chevron.backward"
        )
        configureIconButton(
            nextButton,
            identifier: Self.nextAccessibilityIdentifier,
            accessibilityLabel: "Next month".localizeString(id: "next_month", arguments: []),
            systemImage: "chevron.forward"
        )
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        previousButton.addTarget(self, action: #selector(previousTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        addSubview(closeButton)
        addSubview(previousButton)
        addSubview(nextButton)

        monthButton.accessibilityIdentifier = Self.monthAccessibilityIdentifier
        monthButton.accessibilityLabel = "Choose month and year".localizeString(
            id: "choose_month_year",
            arguments: []
        )
        monthButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        monthButton.titleLabel?.adjustsFontForContentSizeCategory = true
        monthButton.titleLabel?.adjustsFontSizeToFitWidth = true
        monthButton.titleLabel?.minimumScaleFactor = 0.75
        monthButton.setTitleColor(.label, for: .normal)
        monthButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        monthButton.semanticContentAttribute = .forceRightToLeft
        monthButton.tintColor = .secondaryLabel
        monthButton.addTarget(self, action: #selector(monthTapped), for: .touchUpInside)
        addSubview(monthButton)

        addSubview(weekdayContainerView)
        collectionView.backgroundColor = .clear
        collectionView.isScrollEnabled = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            ChatSearchCalendarDayCell.self,
            forCellWithReuseIdentifier: ChatSearchCalendarDayCell.reuseIdentifier
        )
        addSubview(collectionView)

        monthYearPickerContainerView.backgroundColor = .secondarySystemBackground
        monthYearPickerContainerView.layer.cornerRadius = 16
        monthYearPickerContainerView.layer.cornerCurve = .continuous
        monthPicker.dataSource = self
        monthPicker.delegate = self
        yearPicker.dataSource = self
        yearPicker.delegate = self
        pickerCloseButton.setTitle("Close".localizeString(id: "close", arguments: []), for: .normal)
        pickerApplyButton.setTitle("Apply".localizeString(id: "apply", arguments: []), for: .normal)
        pickerCloseButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        pickerApplyButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        pickerCloseButton.titleLabel?.adjustsFontForContentSizeCategory = true
        pickerApplyButton.titleLabel?.adjustsFontForContentSizeCategory = true
        pickerCloseButton.addTarget(self, action: #selector(pickerCloseTapped), for: .touchUpInside)
        pickerApplyButton.addTarget(self, action: #selector(pickerApplyTapped), for: .touchUpInside)
        monthYearPickerContainerView.addSubview(monthPicker)
        monthYearPickerContainerView.addSubview(yearPicker)
        monthYearPickerContainerView.addSubview(pickerCloseButton)
        monthYearPickerContainerView.addSubview(pickerApplyButton)
        addSubview(monthYearPickerContainerView)

        doneButton.accessibilityIdentifier = Self.doneAccessibilityIdentifier
        doneButton.setTitle("Done".localizeString(id: "done", arguments: []), for: .normal)
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.setTitleColor(UIColor.white.withAlphaComponent(0.5), for: .disabled)
        doneButton.backgroundColor = .systemBlue
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.titleLabel?.adjustsFontForContentSizeCategory = true
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        addSubview(doneButton)

        let leftSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedLeft))
        leftSwipe.direction = .left
        let rightSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedRight))
        rightSwipe.direction = .right
        collectionView.addGestureRecognizer(leftSwipe)
        collectionView.addGestureRecognizer(rightSwipe)
        synchronizeSemanticDirection()
    }

    private func configureIconButton(
        _ button: UIButton,
        identifier: String,
        accessibilityLabel: String,
        systemImage: String
    ) {
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = accessibilityLabel
        button.tintColor = .label
        button.setImage(UIImage(systemName: systemImage), for: .normal)
    }

    private func applySnapshot(_ snapshot: ChatSearchCalendarModel.Snapshot) {
        monthButton.setTitle(snapshot.monthTitle, for: .normal)
        previousButton.isEnabled = snapshot.canNavigatePreviousMonth
        nextButton.isEnabled = snapshot.canNavigateNextMonth
        doneButton.isEnabled = snapshot.isDoneEnabled
        doneButton.backgroundColor = snapshot.isDoneEnabled ? .systemBlue : .systemGray3

        rebuildWeekdayLabels(symbols: snapshot.weekdaySymbols)
        yearPickerYears = Array(snapshot.pickerYearRange)
        monthPicker.reloadAllComponents()
        yearPicker.reloadAllComponents()
        let monthRow = min(max(0, snapshot.pickerMonth - 1), max(0, snapshot.pickerMonthSymbols.count - 1))
        if !snapshot.pickerMonthSymbols.isEmpty {
            monthPicker.selectRow(monthRow, inComponent: 0, animated: false)
        }
        if let yearRow = yearPickerYears.firstIndex(of: snapshot.pickerYear) {
            yearPicker.selectRow(yearRow, inComponent: 0, animated: false)
        }
        monthYearPickerContainerView.isHidden = !snapshot.isMonthYearPickerPresented
        weekdayContainerView.isHidden = snapshot.isMonthYearPickerPresented
        collectionView.isHidden = snapshot.isMonthYearPickerPresented
        collectionView.reloadData()
    }

    private func rebuildWeekdayLabels(symbols: [String]) {
        guard weekdayLabels.map(\.text) != symbols.map(Optional.some) else {
            return
        }
        weekdayLabels.forEach { $0.removeFromSuperview() }
        weekdayLabels = symbols.prefix(7).map { symbol in
            let label = UILabel()
            label.text = symbol
            label.textAlignment = .center
            label.font = .preferredFont(forTextStyle: .caption1)
            label.adjustsFontForContentSizeCategory = true
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.textColor = .secondaryLabel
            label.isAccessibilityElement = false
            weekdayContainerView.addSubview(label)
            return label
        }
    }

    private func layoutWeekdayLabels(direction: UIUserInterfaceLayoutDirection) {
        guard !weekdayLabels.isEmpty else { return }
        let columnWidth = weekdayContainerView.bounds.width / 7
        for (index, label) in weekdayLabels.enumerated() {
            let visualIndex = direction == .rightToLeft ? 6 - index : index
            label.frame = CGRect(
                x: CGFloat(visualIndex) * columnWidth,
                y: 0,
                width: columnWidth,
                height: weekdayContainerView.bounds.height
            )
        }
    }

    private func layoutPickerControls(direction: UIUserInterfaceLayoutDirection) {
        let actionHeight: CGFloat = 44
        let pickerHeight = max(0, monthYearPickerContainerView.bounds.height - actionHeight)
        let halfWidth = monthYearPickerContainerView.bounds.width / 2
        let leadingFrame = CGRect(x: 0, y: 0, width: halfWidth, height: pickerHeight)
        let trailingFrame = CGRect(x: halfWidth, y: 0, width: halfWidth, height: pickerHeight)
        monthPicker.frame = direction == .rightToLeft ? trailingFrame : leadingFrame
        yearPicker.frame = direction == .rightToLeft ? leadingFrame : trailingFrame
        pickerCloseButton.frame = CGRect(
            x: 8,
            y: pickerHeight,
            width: max(44, halfWidth - 8),
            height: actionHeight
        )
        pickerApplyButton.frame = CGRect(
            x: halfWidth,
            y: pickerHeight,
            width: max(44, halfWidth - 8),
            height: actionHeight
        )
    }

    private func synchronizeSemanticDirection() {
        let attribute: UISemanticContentAttribute = resolvedLayoutDirection == .rightToLeft
            ? .forceRightToLeft
            : .forceLeftToRight
        weekdayContainerView.semanticContentAttribute = attribute
        collectionView.semanticContentAttribute = attribute
        monthYearPickerContainerView.semanticContentAttribute = attribute
    }

    private func makeMonthContentSnapshot() -> UIView? {
        guard window != nil else { return nil }
        let container = UIView(frame: bounds)
        container.isUserInteractionEnabled = false
        var hasSnapshot = false
        for contentView in monthContentViews where !contentView.isHidden {
            guard let snapshot = contentView.snapshotView(afterScreenUpdates: false) else { continue }
            snapshot.frame = contentView.frame
            container.addSubview(snapshot)
            hasSnapshot = true
        }
        guard hasSnapshot else { return nil }
        addSubview(container)
        bringSubviewToFront(doneButton)
        outgoingMonthSnapshotView = container
        return container
    }

    private func animateMonthContent(
        from outgoing: UIView?,
        travelDirection: ChatSearchAnimationSpec.HorizontalTravelDirection
    ) {
        let visibleContent = monthContentViews.filter { !$0.isHidden }
        let distance = max(1, bounds.width)
        switch animationSpec.monthSwipe.mode {
        case .horizontalSlide:
            let sign: CGFloat = travelDirection == .left ? 1 : -1
            visibleContent.forEach {
                $0.transform = CGAffineTransform(translationX: sign * distance, y: 0)
            }
            outgoing?.transform = .identity
        case .crossfade:
            visibleContent.forEach { $0.alpha = 0 }
            outgoing?.alpha = 1
        }

        let animator = UIViewPropertyAnimator(
            duration: animationSpec.monthSwipe.timing.duration,
            curve: .easeInOut
        ) {
            visibleContent.forEach {
                $0.transform = .identity
                $0.alpha = 1
            }
            if self.animationSpec.monthSwipe.mode == .horizontalSlide {
                let outgoingSign: CGFloat = travelDirection == .left ? -1 : 1
                outgoing?.transform = CGAffineTransform(translationX: outgoingSign * distance, y: 0)
            } else {
                outgoing?.alpha = 0
            }
        }
        animator.addCompletion { [weak self, weak outgoing] _ in
            visibleContent.forEach {
                $0.transform = .identity
                $0.alpha = 1
            }
            outgoing?.removeFromSuperview()
            self?.runningMonthAnimator = nil
        }
        runningMonthAnimator = animator
        animator.startAnimation()
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func previousTapped() { onPreviousMonth?() }
    @objc private func nextTapped() { onNextMonth?() }
    @objc private func monthTapped() { onToggleMonthYearPicker?() }
    @objc private func pickerCloseTapped() { onDismissMonthYearPicker?() }
    @objc private func pickerApplyTapped() { onApplyMonthYearPicker?() }
    @objc private func doneTapped() { onDone?() }
    @objc private func swipedLeft() { handleSwipe(.left) }
    @objc private func swipedRight() { handleSwipe(.right) }
}

extension ChatSearchCalendarView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        renderedSnapshot?.daySlots.count ?? 0
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ChatSearchCalendarDayCell.reuseIdentifier,
            for: indexPath
        ) as? ChatSearchCalendarDayCell,
        let slot = renderedSnapshot?.daySlots[indexPath.item] else {
            return UICollectionViewCell()
        }
        cell.configure(with: slot)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let slot = renderedSnapshot?.daySlots[indexPath.item], slot.isInteractive else {
            return
        }
        onSelectDay?(slot.id)
    }
}

extension ChatSearchCalendarView: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        if pickerView === monthPicker {
            return renderedSnapshot?.pickerMonthSymbols.count ?? 0
        }
        return yearPickerYears.count
    }

    func pickerView(
        _ pickerView: UIPickerView,
        titleForRow row: Int,
        forComponent component: Int
    ) -> String? {
        if pickerView === monthPicker {
            guard let symbols = renderedSnapshot?.pickerMonthSymbols, symbols.indices.contains(row) else {
                return nil
            }
            return symbols[row]
        }
        guard yearPickerYears.indices.contains(row) else { return nil }
        return String(yearPickerYears[row])
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        let month = monthPicker.selectedRow(inComponent: 0) + 1
        let yearRow = yearPicker.selectedRow(inComponent: 0)
        guard (1...12).contains(month), yearPickerYears.indices.contains(yearRow) else {
            return
        }
        onSelectMonthYear?(month, yearPickerYears[yearRow])
    }
}
