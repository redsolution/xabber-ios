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

    private let policy: ScheduledMessageDatePolicy
    private let nowProvider: () -> Date
    private let onConfirm: (Date) -> Void
    private let dimView = UIView()
    private let sheetView = UIView()
    private let titleLabel = UILabel()
    private let datePicker = UIDatePicker()
    private let confirmButton = UIButton(type: .system)

    init(
        policy: ScheduledMessageDatePolicy = ScheduledMessageDatePolicy(),
        nowProvider: @escaping () -> Date = Date.init,
        onConfirm: @escaping (Date) -> Void
    ) {
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
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.text = "Schedule Message".localizeString(id: "schedule_message_action", arguments: [])
        sheetView.addSubview(titleLabel)

        datePicker.translatesAutoresizingMaskIntoConstraints = false
        datePicker.datePickerMode = .dateAndTime
        datePicker.preferredDatePickerStyle = .wheels
        datePicker.minuteInterval = 1
        datePicker.locale = policy.locale
        datePicker.timeZone = policy.timeZone
        datePicker.accessibilityIdentifier = Self.datePickerIdentifier
        datePicker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
        sheetView.addSubview(datePicker)

        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
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

            confirmButton.topAnchor.constraint(equalTo: datePicker.bottomAnchor, constant: 8),
            confirmButton.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 20),
            confirmButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -20),
            confirmButton.heightAnchor.constraint(equalToConstant: 48),
            confirmButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    private func configureDatePicker() {
        let now = nowProvider()
        let minimumDate = policy.minimumDate(now: now)
        let normalizedMinimumDate = policy.normalizedToMinute(minimumDate)
        datePicker.minimumDate = minimumDate
        datePicker.date = policy.canConfirm(normalizedMinimumDate, now: now)
            ? normalizedMinimumDate
            : (policy.calendar.date(byAdding: .minute, value: 1, to: normalizedMinimumDate) ?? minimumDate)
    }

    @objc
    private func dateChanged() {
        updateConfirmButton()
    }

    private func updateConfirmButton() {
        let now = nowProvider()
        let selectedDate = policy.normalizedToMinute(datePicker.date)
        confirmButton.setTitle(policy.confirmTitle(for: selectedDate, now: now), for: .normal)
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
}
