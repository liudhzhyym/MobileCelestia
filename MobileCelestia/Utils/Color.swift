//
// Color.swift
//
// Copyright © 2020 Celestia Development Team. All rights reserved.
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//

import UIKit

public extension UIColor {
    convenience init(red: Int, green: Int, blue: Int) {
        assert(red >= 0 && red <= 255, "Invalid red component")
        assert(green >= 0 && green <= 255, "Invalid green component")
        assert(blue >= 0 && blue <= 255, "Invalid blue component")

        self.init(red: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: 1.0)
    }

    convenience init(rgb: Int) {
        self.init(
            red: (rgb >> 16) & 0xFF,
            green: (rgb >> 8) & 0xFF,
            blue: rgb & 0xFF
        )
    }
}

extension UIColor {
    class var lightSeparator: UIColor {
        return UIColor(rgb: 0x3C3C43).withAlphaComponent(0.29)
    }

    class var darkSeparator: UIColor {
        return UIColor(rgb: 0x545458).withAlphaComponent(0.6)
    }

    class var lightLabel: UIColor {
        return UIColor.black
    }

    class var darkLabel: UIColor {
        return UIColor.white
    }

    class var lightSecondaryLabel: UIColor {
        return UIColor(rgb: 0x3C3C43).withAlphaComponent(0.6)
    }

    class var darkSecondaryLabel: UIColor {
        return UIColor(rgb: 0xEBEBF5).withAlphaComponent(0.6)
    }

    class var lightTertiaryLabel: UIColor {
        return UIColor(rgb: 0x3C3C43).withAlphaComponent(0.3)
    }

    class var darkTertiaryLabel: UIColor {
        return UIColor(rgb: 0xEBEBF5).withAlphaComponent(0.3)
    }

    class var lightSelection: UIColor {
        return UIColor(rgb: 0xD1D1D6)
    }

    class var darkSelection: UIColor {
        return UIColor(rgb: 0x3A3A3C)
    }

    class var lightBackground: UIColor {
        return UIColor.white
    }

    class var darkBackground: UIColor {
        return UIColor.black
    }

    class var lightSecondaryBackground: UIColor {
        return UIColor(rgb: 0xF2F2F7)
    }

    class var darkSecondaryBackground: UIColor {
        return UIColor(rgb: 0x1C1C1E)
    }

    class var darkPlainHeaderBackground: UIColor {
        return UIColor(rgb: 0x323234)
    }

    class var lightPlainHeaderBackground: UIColor {
        return UIColor(rgb: 0xE5E5E5)
    }

    class var darkPlainHeaderLabel: UIColor {
        return UIColor(rgb: 0xDCDCDC)
    }

    class var lightPlainHeaderLabel: UIColor {
        return UIColor(rgb: 0x232323)
    }

    class var darkGroupHeaderFooterLabel: UIColor {
        return UIColor(rgb: 0x8E8E93)
    }

    class var lightGroupHeaderFooterLabel: UIColor {
        return UIColor(rgb: 0x6D6D72)
    }

    class var darkSystemBlueColor: UIColor {
        return UIColor(rgb: 0x0A84FF)
    }

    class var lightSystemBlueColor: UIColor {
        return UIColor(rgb: 0x007AFF)
    }

    class var darkSliderMinimumTrackTintColor: UIColor {
        return darkSystemBlueColor
    }

    class var lightSliderMinimumTrackTintColor: UIColor {
        return lightSystemBlueColor
    }
}

extension UIColor {
    class var themeBackground: UIColor {
        return UIColor(rgb: 0x114477)
    }

    class var themeLabel: UIColor {
        return UIColor(rgb: 0x6699CC)
    }
}
