import Foundation
import Testing
import UIKit
@testable import Forme

@Suite("Piece")
struct PieceTests {
    @Test("Survives a Codable round trip with a source asset")
    func codableRoundTripWithSourceAsset() throws {
        let piece = Piece(
            id: UUID(),
            category: .outerwear,
            imageFileName: "coat.png",
            sourceAssetID: "ASSET-1",
            createdAt: Date()
        )

        let decoded = try JSONDecoder().decode(Piece.self, from: JSONEncoder().encode(piece))

        #expect(decoded == piece)
    }

    @Test("Survives a Codable round trip without a source asset")
    func codableRoundTripWithoutSourceAsset() throws {
        let piece = Piece(
            id: UUID(),
            category: .shoes,
            imageFileName: "boots.png",
            sourceAssetID: nil,
            createdAt: Date()
        )

        let decoded = try JSONDecoder().decode(Piece.self, from: JSONEncoder().encode(piece))

        #expect(decoded == piece)
        #expect(decoded.sourceAssetID == nil)
        #expect(decoded.capturedAt == nil)
    }

    @Test("capturedAt survives a Codable round trip")
    func capturedAtRoundTrips() throws {
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        let piece = Piece(
            id: UUID(),
            category: .top,
            imageFileName: "tee.png",
            sourceAssetID: "ASSET-3",
            createdAt: Date(),
            capturedAt: taken
        )

        let decoded = try JSONDecoder().decode(Piece.self, from: JSONEncoder().encode(piece))

        #expect(decoded == piece)
        #expect(decoded.capturedAt == taken)
    }

    @Test("An index written before capturedAt existed still decodes")
    func decodesLegacyJSONWithoutCapturedAt() throws {
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "category": "top",
            "imageFileName": "old.png",
            "createdAt": 700000000
        }
        """

        let decoded = try JSONDecoder().decode(Piece.self, from: Data(json.utf8))

        #expect(decoded.id == id)
        #expect(decoded.capturedAt == nil)
        #expect(decoded.sourceAssetID == nil)
    }

    @Test("Every category has a name a person would recognise")
    func categoryDisplayNames() {
        for category in Piece.Category.allCases {
            #expect(!category.displayName.isEmpty)
            #expect(category.displayName.first?.isUppercase == true)
        }
    }

    @Test("Every category symbol exists in SF Symbols")
    func categorySymbolsResolve() {
        for category in Piece.Category.allCases {
            #expect(
                UIImage(systemName: category.symbolName) != nil,
                "\(category.rawValue) uses a symbol that doesn't exist"
            )
        }
    }
}

@Suite("Garment label map")
struct GarmentLabelMapTests {
    @Test("Dress labels suggest a dress")
    func mapsDress() {
        #expect(GarmentLabelMap.category(for: ["dress"]) == .dress)
        #expect(GarmentLabelMap.category(for: ["gown"]) == .dress)
    }

    @Test("Leg-wear labels suggest a bottom")
    func mapsBottom() {
        #expect(GarmentLabelMap.category(for: ["pants"]) == .bottom)
        #expect(GarmentLabelMap.category(for: ["jeans"]) == .bottom)
        #expect(GarmentLabelMap.category(for: ["skirt"]) == .bottom)
    }

    @Test("Footwear labels suggest shoes")
    func mapsShoes() {
        #expect(GarmentLabelMap.category(for: ["sneaker"]) == .shoes)
        #expect(GarmentLabelMap.category(for: ["high_heel"]) == .shoes)
    }

    @Test("Coats and jackets suggest outerwear")
    func mapsOuterwear() {
        #expect(GarmentLabelMap.category(for: ["jacket"]) == .outerwear)
        #expect(GarmentLabelMap.category(for: ["cloak"]) == .outerwear)
    }

    @Test("Worn extras suggest an accessory")
    func mapsAccessory() {
        #expect(GarmentLabelMap.category(for: ["sunglasses"]) == .accessory)
        #expect(GarmentLabelMap.category(for: ["handbag"]) == .accessory)
    }

    @Test("Upper-body labels suggest a top")
    func mapsTop() {
        #expect(GarmentLabelMap.category(for: ["hoodie"]) == .top)
        #expect(GarmentLabelMap.category(for: ["shirt"]) == .top)
    }

    @Test("Label matching ignores case")
    func matchingIgnoresCase() {
        #expect(GarmentLabelMap.category(for: ["Sneaker"]) == .shoes)
    }

    @Test("An unrecognised label falls back to other, never to a wrong guess")
    func mapsUnknownToOther() {
        #expect(GarmentLabelMap.category(for: ["labrador_retriever"]) == .other)
        #expect(GarmentLabelMap.category(for: []) == .other)
    }

    @Test("A dress label outranks a top label in the same photo")
    func priorityPrefersTheMoreSpecificGarment() {
        #expect(GarmentLabelMap.category(for: ["shirt", "dress"]) == .dress)
    }
}
