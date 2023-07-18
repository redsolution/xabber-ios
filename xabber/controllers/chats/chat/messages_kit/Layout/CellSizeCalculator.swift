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

/// An object is responsible for
/// sizing and configuring cells for given `IndexPath`s.
open class CellSizeCalculator {

    /// The layout object for which the cell size calculator is used.
    public weak var layout: UICollectionViewFlowLayout?

    /// Used to configure the layout attributes for a given cell.
    ///
    /// - Parameters:
    /// - attributes: The attributes of the cell.
    /// The default does nothing
    open func configure(attributes: UICollectionViewLayoutAttributes) {}

    /// Used to size an item at a given `IndexPath`.
    ///
    /// - Parameters:
    /// - indexPath: The `IndexPath` of the item to be displayed.
    /// The default return .zero
    open func sizeForItem(at indexPath: IndexPath) -> CGSize { return .zero }
    
    public init() {}

}
