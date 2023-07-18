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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation

public final class Chronometer: NSObject {
	private var timer: Timer?
	private var timeInterval: TimeInterval = 1.0

	public var isPlaying = false
	public var timerCurrentValue: TimeInterval = 0.0

	public var timerDidUpdate: ((TimeInterval) -> ())?
	public var timerDidComplete: (() -> ())?

	public init(withTimeInterval timeInterval: TimeInterval = 0.0) {
		super.init()

		self.timeInterval = timeInterval
	}

	public func start(shouldFire fire: Bool = true) {
		self.timer = Timer(timeInterval: self.timeInterval, target: self, selector: #selector(Chronometer.timerDidTrigger), userInfo: nil, repeats: true)
        RunLoop.main.add(self.timer!, forMode: .default)
		self.timer?.fire()
		self.isPlaying = true
	}

	public func pause() {
		self.timer?.invalidate()
		self.timer = nil
		self.isPlaying = false
	}

	public func stop() {
		self.isPlaying = false
		self.timer?.invalidate()
		self.timer = nil
		self.timerCurrentValue = 0.0
		self.timerDidComplete?()
	}

	// MARK: - Private

	@objc fileprivate func timerDidTrigger() {
		self.timerDidUpdate?(self.timerCurrentValue)
		self.timerCurrentValue += self.timeInterval
	}
}
