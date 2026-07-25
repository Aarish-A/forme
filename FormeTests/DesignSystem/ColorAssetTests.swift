import SwiftUI
import Testing
@testable import Forme

/// Guards the failure the compiler can't see.
///
/// Generated asset symbols prove a colorset *exists* — `Theme.Colors.surface`
/// won't compile if the colorset is renamed. Nothing proves it has a dark
/// variant, and a colorset missing one renders its light value on a black
/// background: invisible text, shipped.
///
/// Reading `Contents.json` would only check what was declared, and the compiled
/// catalog doesn't ship it anyway. Resolving in both appearances checks what a
/// user actually gets.
@Suite("Colour assets")
struct ColorAssetTests {
    @Test(
        "Every brand colour has a distinct dark appearance",
        arguments: ColorToken.brandDefined
    )
    func hasDarkVariant(token: ColorToken) {
        var light = EnvironmentValues()
        light.colorScheme = .light
        var dark = EnvironmentValues()
        dark.colorScheme = .dark

        #expect(
            token.color.resolve(in: light) != token.color.resolve(in: dark),
            """
            '\(token.rawValue)' resolves identically in light and dark. Either its colorset \
            is missing a dark appearance, or that's deliberate — in which case take it out \
            of ColorToken.brandDefined and say why.
            """
        )
    }
}
