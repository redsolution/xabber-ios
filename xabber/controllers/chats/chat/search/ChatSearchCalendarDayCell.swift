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

final class ChatSearchCalendarDayCell: UICollectionViewCell {
    enum VisualCue: Equatable {
        case none
        case todayRing
        case selected
        case selectedEmphasized
    }

    enum Colors {
        static let day = UIColor.label
        static let today = UIColor.systemBlue
        static let disabled = UIColor.tertiaryLabel
        static let selectedFill = UIColor.systemBlue
        static let selectedText = UIColor { traits in
            let fill = selectedFill.resolvedColor(with: traits)
            return ChatSearchContrastPolicy.passesLargeOrControlText(
                foreground: .white,
                background: fill,
                compatibleWith: traits
            ) ? .white : .black
        }
    }

    static let reuseIdentifier = "ChatSearchCalendarDayCell"
    static let accessibilityIdentifier = ChatSearchAccessibilityIdentifier.calendarDay
    private(set) var adaptiveEnvironment = ChatSearchAdaptiveEnvironment.standard
    private(set) var visualCue: VisualCue = .none

    let selectionCircleView: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }()

    let dayLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        contentView.addSubview(selectionCircleView)
        contentView.addSubview(dayLabel)
        applyAdaptiveEnvironment(.current(for: self))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isAccessibilityElement = true
        contentView.addSubview(selectionCircleView)
        contentView.addSubview(dayLabel)
        applyAdaptiveEnvironment(.current(for: self))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = min(
            ChatSearchAdaptiveLayoutPolicy.calendarDayIndicatorDiameter,
            max(0, min(contentView.bounds.width, contentView.bounds.height) - 4)
        )
        selectionCircleView.frame = CGRect(
            x: contentView.bounds.midX - diameter / 2,
            y: contentView.bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        selectionCircleView.layer.cornerRadius = diameter / 2
        selectionCircleView.layer.cornerCurve = .continuous
        dayLabel.frame = contentView.bounds.insetBy(dx: 2, dy: 2)
        updateChatSearchAccessibilityFrame()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateChatSearchAccessibilityFrame()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory ||
                previousTraitCollection?.accessibilityContrast != traitCollection.accessibilityContrast ||
                previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else {
            return
        }
        applyAdaptiveEnvironment(.current(for: self))
    }

    func applyAdaptiveEnvironment(_ environment: ChatSearchAdaptiveEnvironment) {
        adaptiveEnvironment = environment
        semanticContentAttribute = environment.layoutDirection == .rightToLeft
            ? .forceRightToLeft
            : .forceLeftToRight
        dayLabel.font = ChatSearchAdaptiveLayoutPolicy.scaledFont(
            baseSize: 17,
            weight: .regular,
            textStyle: .body,
            contentSizeCategory: environment.contentSizeCategory
        )
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetState()
    }

    func configure(
        with slot: ChatSearchCalendarModel.DaySlot,
        localization: ChatSearchLocalization = .production(),
        formatting: ChatSearchFormatting? = nil
    ) {
        resetState()

        guard slot.isInVisibleMonth, let dayNumber = slot.dayNumber else {
            return
        }

        dayLabel.text = String(dayNumber)
        accessibilityIdentifier = ChatSearchAccessibilityIdentifier.calendarDay(slot.id)
        isAccessibilityElement = true
        isUserInteractionEnabled = slot.isInteractive
        accessibilityTraits = [.button]

        if let date = slot.date {
            let formatting = formatting ?? ChatSearchFormatting(
                locale: localization.locale,
                calendar: .autoupdatingCurrent,
                timeZone: .autoupdatingCurrent
            )
            accessibilityLabel = formatting.fullDate(for: date)
        } else {
            accessibilityLabel = String(dayNumber)
        }

        var valueComponents: [String] = []
        if slot.isSelected {
            accessibilityTraits.insert(.selected)
            valueComponents.append(localization.text(.selected))
        }
        if slot.isToday {
            valueComponents.append(localization.text(.today))
        }
        if !slot.isEnabled {
            accessibilityTraits.insert(.notEnabled)
        }
        accessibilityValue = valueComponents.isEmpty ? nil : valueComponents.joined(separator: ", ")

        selectionCircleView.isHidden = !slot.isSelected && !slot.isToday
        if slot.isSelected {
            visualCue = adaptiveEnvironment.differentiateWithoutColor ||
                adaptiveEnvironment.accessibilityContrast == .high
                ? .selectedEmphasized
                : .selected
        } else if slot.isToday {
            visualCue = .todayRing
        }
        switch visualCue {
        case .selectedEmphasized:
            selectionCircleView.layer.borderWidth = 2
            selectionCircleView.layer.borderColor = selectedTextColor.cgColor
        case .todayRing:
            selectionCircleView.layer.borderWidth = adaptiveEnvironment.accessibilityContrast == .high
                ? 2
                : 1.5
            selectionCircleView.layer.borderColor = Colors.today.cgColor
        case .selected, .none:
            selectionCircleView.layer.borderWidth = 0
            selectionCircleView.layer.borderColor = nil
        }
        selectionCircleView.backgroundColor = slot.isSelected ? Colors.selectedFill : .clear

        if slot.isSelected {
            dayLabel.textColor = selectedTextColor
        } else if !slot.isEnabled {
            dayLabel.textColor = adaptiveEnvironment.accessibilityContrast == .high
                ? .secondaryLabel
                : Colors.disabled
        } else if slot.isToday {
            dayLabel.textColor = Colors.today
        } else {
            dayLabel.textColor = Colors.day
        }
        setNeedsLayout()
    }

    private var selectedTextColor: UIColor {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: adaptiveEnvironment.userInterfaceStyle),
            UITraitCollection(accessibilityContrast: adaptiveEnvironment.accessibilityContrast)
        ])
        return Colors.selectedText.resolvedColor(with: traits)
    }

    private func resetState() {
        dayLabel.text = nil
        dayLabel.textColor = Colors.day
        selectionCircleView.isHidden = true
        selectionCircleView.backgroundColor = .clear
        selectionCircleView.layer.borderWidth = 0
        selectionCircleView.layer.borderColor = nil
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityTraits = []
        visualCue = .none
    }
}
