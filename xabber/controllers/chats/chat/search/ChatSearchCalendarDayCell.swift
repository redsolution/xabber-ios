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
    enum Colors {
        static let day = UIColor.label
        static let today = UIColor.systemBlue
        static let disabled = UIColor.tertiaryLabel
        static let selectedFill = UIColor.systemBlue
        static let selectedText = UIColor.white
    }

    static let reuseIdentifier = "ChatSearchCalendarDayCell"
    static let accessibilityIdentifier = "chat_search_calendar_day"

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
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isAccessibilityElement = true
        contentView.addSubview(selectionCircleView)
        contentView.addSubview(dayLabel)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = min(36, min(contentView.bounds.width, contentView.bounds.height) - 4)
        selectionCircleView.frame = CGRect(
            x: contentView.bounds.midX - diameter / 2,
            y: contentView.bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        selectionCircleView.layer.cornerRadius = diameter / 2
        selectionCircleView.layer.cornerCurve = .continuous
        dayLabel.frame = contentView.bounds.insetBy(dx: 2, dy: 2)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetState()
    }

    func configure(with slot: ChatSearchCalendarModel.DaySlot) {
        resetState()

        guard slot.isInVisibleMonth, let dayNumber = slot.dayNumber else {
            return
        }

        dayLabel.text = String(dayNumber)
        accessibilityIdentifier = Self.accessibilityIdentifier
        isAccessibilityElement = true
        isUserInteractionEnabled = slot.isInteractive

        if let date = slot.date {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            accessibilityLabel = formatter.string(from: date)
        } else {
            accessibilityLabel = String(dayNumber)
        }

        var valueComponents: [String] = []
        if slot.isSelected {
            accessibilityTraits.insert(.selected)
            valueComponents.append("Selected".localizeString(id: "selected", arguments: []))
        }
        if slot.isToday {
            valueComponents.append("Today".localizeString(id: "today", arguments: []))
        }
        if !slot.isEnabled {
            accessibilityTraits.insert(.notEnabled)
        }
        accessibilityValue = valueComponents.isEmpty ? nil : valueComponents.joined(separator: ", ")

        selectionCircleView.isHidden = !slot.isSelected && !slot.isToday
        selectionCircleView.layer.borderWidth = slot.isToday && !slot.isSelected ? 1.5 : 0
        selectionCircleView.layer.borderColor = Colors.today.cgColor
        selectionCircleView.backgroundColor = slot.isSelected ? Colors.selectedFill : .clear

        if slot.isSelected {
            dayLabel.textColor = Colors.selectedText
        } else if !slot.isEnabled {
            dayLabel.textColor = Colors.disabled
        } else if slot.isToday {
            dayLabel.textColor = Colors.today
        } else {
            dayLabel.textColor = Colors.day
        }
        setNeedsLayout()
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
    }
}
