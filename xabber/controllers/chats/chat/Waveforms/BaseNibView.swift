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

import UIKit


public class BaseNibView: UIView {
	@IBOutlet var contentView: UIView!

/**
 *  Is called when the nib name associated with the class is going to be loaded.
 *
 *  @return The nib name (Default implementation returns class name: `NSStringFromClass([self class])`)
 *  You will want to override this method in swift as the class name is prefixed with the module in that case
 */
	var nibName: String {
		return String(describing: type(of: self))
	}
	
/**
 *  Called when first loading the nib.
 *  Defaults to `[NSBundle bundleForClass:[self class]]`
 *
 *  @return The bundle in which to find the nib.
 */
	var nibBundle: Bundle {
		return Bundle(for: type(of: self))
	}
	
/**
 *  Use the 2 methods above to instanciate the correct instance of UINib for the view.
 *  You can override this if you need more customization.
 *
 *  @return An instance of UINib
 */
	var nib: UINib {
		return UINib(nibName: self.nibName, bundle: self.nibBundle)
	}
	
	private var shouldAwakeFromNib: Bool = true
	
	override init(frame: CGRect) {
		super.init(frame: frame)
		self.createFromNib()
	}
	
	required public init?(coder aDecoder: NSCoder) {
		super.init(coder: aDecoder)
	}
	
	override public func awakeFromNib() {
		super.awakeFromNib()
		
		self.shouldAwakeFromNib = false
		self.createFromNib()
	}
	
	private func createFromNib() {
		if self.contentView == nil {
			return
		}
		
		self.nib.instantiate(withOwner: self, options: nil)
		assert(self.contentView != nil, "contentView is nil. Did you forgot to link it in IB?")
		
		if self.shouldAwakeFromNib {
			self.awakeFromNib()
		}
		
		self.contentView.translatesAutoresizingMaskIntoConstraints = false
		self.addSubview(self.contentView)
		
		let leadingConstraint = NSLayoutConstraint(item: self.contentView, attribute: .leading, relatedBy: .equal, toItem: self, attribute: .leading, multiplier: 1.0, constant: 0.0)
		let topConstraint = NSLayoutConstraint(item: self.contentView, attribute: .top, relatedBy: .equal, toItem: self, attribute: .top, multiplier: 1.0, constant: 0.0)
		let trailingConstraint = NSLayoutConstraint(item: self.contentView, attribute: .trailing, relatedBy: .equal, toItem: self, attribute: .trailing, multiplier: 1.0, constant: 0.0)
		let bottomConstraint = NSLayoutConstraint(item: self.contentView, attribute: .bottom, relatedBy: .equal, toItem: self, attribute: .bottom, multiplier: 1.0, constant: 0.0)

		self.addConstraints([leadingConstraint, topConstraint, trailingConstraint, bottomConstraint])
	}
}
