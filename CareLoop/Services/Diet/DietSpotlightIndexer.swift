import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

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
            attrs.displayName = recipe.name
            attrs.contentDescription = [
                recipe.cuisine,
                recipe.tags.joined(separator: "、"),
                recipe.ingredients.joined(separator: "、"),
                recipe.cookingNote,
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            attrs.keywords = recipe.tags + recipe.ingredients + recipe.mealType + [recipe.id]
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
            attrs.displayName = clause.title
            attrs.contentDescription = "\(clause.body) 来源：\(clause.source)"
            attrs.keywords = clause.tags + [clause.source, clause.id]
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

    static func searchClauseIDs(matching query: String) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if #available(iOS 18.0, *) {
            let ranked = await searchWithUserQuery(trimmed)
            if !ranked.isEmpty { return ranked }
        }
        return await searchWithLegacyQuery(trimmed)
    }

    @available(iOS 18.0, *)
    private static func searchWithUserQuery(_ query: String) async -> [String] {
        CSUserQuery.prepare()
        let context = CSUserQueryContext()
        context.fetchAttributes = ["title", "contentDescription", "displayName", "keywords"]
        context.enableRankedResults = true
        context.maxRankedResultCount = 10
        let userQuery = CSUserQuery(userQueryString: query, userQueryContext: context)
        var identifiers: [String] = []
        do {
            for try await element in userQuery.responses {
                switch element {
                case .item(let item):
                    guard item.item.domainIdentifier == domainIdentifier else { continue }
                    if let id = clauseID(from: item.item.uniqueIdentifier) {
                        identifiers.append(id)
                    }
                default:
                    continue
                }
            }
        } catch {
            return []
        }
        return identifiers
    }

    private static func searchWithLegacyQuery(_ query: String) async -> [String] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let queryString = """
        domainIdentifier == '\(domainIdentifier)' && \
        ((title == '\(escaped)*'cd) || (contentDescription == '\(escaped)*'cd) || (keywords == '\(escaped)*'cd))
        """
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title", "contentDescription"]
        let search = CSSearchQuery(queryString: queryString, queryContext: context)
        var identifiers: [String] = []
        do {
            for try await result in search.results {
                if let id = clauseID(from: result.item.uniqueIdentifier) {
                    identifiers.append(id)
                }
            }
        } catch {
            return identifiers
        }
        return identifiers
    }

    static func clauseID(from uniqueIdentifier: String) -> String? {
        let prefix = "clause:"
        guard uniqueIdentifier.hasPrefix(prefix) else { return nil }
        return String(uniqueIdentifier.dropFirst(prefix.count))
    }
}
