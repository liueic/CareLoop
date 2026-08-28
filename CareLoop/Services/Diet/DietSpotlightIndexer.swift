import CoreSpotlight
import Foundation

enum DietSpotlightIndexer {
    static let domainIdentifier = "careloop.diet"

    static func reindex(
        recipes: [Recipe],
        dietRules: DietGuidelineRules
    ) {
        var items: [CSSearchableItem] = []
        for recipe in recipes {
            let attrs = CSSearchableItemAttributeSet(contentType: .content)
            attrs.title = recipe.name
            attrs.contentDescription = [recipe.cuisine, recipe.tags.joined(separator: "、"), recipe.cookingNote]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            attrs.keywords = recipe.tags + recipe.ingredients + recipe.mealType
            items.append(
                CSSearchableItem(
                    uniqueIdentifier: "recipe:\(recipe.id)",
                    domainIdentifier: domainIdentifier,
                    attributeSet: attrs
                )
            )
        }
        for clause in dietRules.clauses {
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = clause.title
            attrs.contentDescription = clause.body
            attrs.keywords = clause.tags + [clause.source]
            items.append(
                CSSearchableItem(
                    uniqueIdentifier: "clause:\(clause.id)",
                    domainIdentifier: domainIdentifier,
                    attributeSet: attrs
                )
            )
        }
        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error {
                print("DietSpotlightIndexer error: \(error.localizedDescription)")
            }
        }
    }

    static func deleteAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in }
    }
}
