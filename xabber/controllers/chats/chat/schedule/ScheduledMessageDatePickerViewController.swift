//
//  ScheduledMessageDatePickerViewController.swift
//  xabber
//
//  Created by Codex on 15.06.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import UIKit

final class ScheduledMessageDatePickerViewController: UIViewController {
    static let accessibilityIdentifier = "chat.schedule.date_picker.sheet"
    static let datePickerIdentifier = "chat.schedule.date_picker"
    static let confirmButtonIdentifier = "chat.schedule.date_picker.confirm"
    static let countdownIdentifier = "chat.schedule.date_picker.countdown"

    private let policy: ScheduledMessageDatePolicy
    private let nowProvider: () -> Date
    private let initialDate: Date?
    private let onConfirm: (Date) -> Void
    private let dimView = UIView()
    private let sheetView = UIView()
    private let titleLabel = UILabel()
    private let datePicker = UIDatePicker()
    private let countdownLabel = UILabel()
    private let confirmButton = UIButton(type: .system)

    init(
        initialDate: Date? = nil,
        policy: ScheduledMessageDatePolicy = ScheduledMessageDatePolicy(
            calendar: L10n.formatters.calendar,
            locale: L10n.formatters.locale,
            timeZone: L10n.formatters.timeZone
        ),
        nowProvider: @escaping () -> Date = Date.init,
        onConfirm: @escaping (Date) -> Void
    ) {
        self.initialDate = initialDate
        self.policy = policy
        self.nowProvider = nowProvider
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .coverVertical
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = Self.accessibilityIdentifier
        setupViews()
        configureDatePicker()
        updateConfirmButton()
    }

    private func setupViews() {
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        view.addSubview(dimView)
        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))

        sheetView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.backgroundColor = .systemBackground
        sheetView.layer.cornerRadius = 18
        sheetView.layer.cornerCurve = .continuous
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheetView.clipsToBounds = true
        view.addSubview(sheetView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textAlignment = .center
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textColor = .label
        titleLabel.accessibilityTraits.insert(.header)
        titleLabel.text = initialDate == nil
            ? L10n.text("schedule_message_action", fallback: "Schedule Message")
            : L10n.text("scheduled_message_reschedule", fallback: "Reschedule")
        sheetView.addSubview(titleLabel)

        datePicker.translatesAutoresizingMaskIntoConstraints = false
        datePicker.datePickerMode = .dateAndTime
        datePicker.preferredDatePickerStyle = .wheels
        datePicker.minuteInterval = 1
        datePicker.locale = policy.locale
        datePicker.calendar = policy.calendar
        datePicker.timeZone = policy.timeZone
        datePicker.accessibilityIdentifier = Self.datePickerIdentifier
        datePicker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
        sheetView.addSubview(datePicker)

        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        countdownLabel.textAlignment = .center
        countdownLabel.textColor = .secondaryLabel
        countdownLabel.font = .preferredFont(forTextStyle: .subheadline)
        countdownLabel.adjustsFontForContentSizeCategory = true
        countdownLabel.numberOfLines = 0
        countdownLabel.accessibilityIdentifier = Self.countdownIdentifier
        sheetView.addSubview(countdownLabel)

        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        confirmButton.titleLabel?.adjustsFontForContentSizeCategory = true
        confirmButton.titleLabel?.numberOfLines = 0
        confirmButton.titleLabel?.textAlignment = .center
        confirmButton.accessibilityIdentifier = Self.confirmButtonIdentifier
        confirmButton.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        sheetView.addSubview(confirmButton)

        NSLayoutConstraint.activate([
            sheetView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: sheetView.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -20),

            datePicker.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            datePicker.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            datePicker.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),

            countdownLabel.topAnchor.constraint(equalTo: datePicker.bottomAnchor, constant: 4),
            countdownLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            countdownLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            confirmButton.topAnchor.constraint(equalTo: countdownLabel.bottomAnchor, constant: 8),
            confirmButton.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 20),
            confirmButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -20),
            confirmButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            confirmButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    private func configureDatePicker() {
        let now = nowProvider()
        datePicker.minimumDate = policy.initialDate(preferred: now, now: now)
        datePicker.date = policy.initialDate(preferred: initialDate, now: now)
    }

    @objc
    private func dateChanged() {
        updateConfirmButton()
    }

    private func updateConfirmButton() {
        let now = nowProvider()
        let selectedDate = policy.normalizedToMinute(datePicker.date)
        let title = initialDate == nil
            ? policy.confirmTitle(for: selectedDate, now: now)
            : L10n.text("scheduled_message_reschedule", fallback: "Reschedule")
        confirmButton.setTitle(title, for: .normal)
        countdownLabel.text = policy.countdown(for: selectedDate, now: now)
        confirmButton.isEnabled = policy.canConfirm(selectedDate, now: now)
        confirmButton.alpha = confirmButton.isEnabled ? 1 : 0.45
    }

    @objc
    private func confirm() {
        let selectedDate = policy.normalizedToMinute(datePicker.date)
        guard policy.canConfirm(selectedDate, now: nowProvider()) else {
            updateConfirmButton()
            return
        }
        dismiss(animated: true) { [onConfirm] in
            onConfirm(selectedDate)
        }
    }

    @objc
    private func close() {
        dismiss(animated: true)
    }

    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }
}
