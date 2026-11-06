import Foundation

public struct WebSearchResult: Codable, Sendable, Equatable {
    public let title: String
    public let snippet: String
    public let url: String

    public init(title: String, snippet: String, url: String) {
        self.title = title
        self.snippet = snippet
        self.url = url
    }
}

/// Por qué falló una búsqueda. Antes todos estos casos devolvían un resultado fabricado
/// ("Búsqueda web: <consulta>") que el tool presentaba como éxito, así que sin red el
/// agente le contaba al usuario un "resultado" vacío como si fuera lo que dice internet.
public enum WebSearchError: Error, LocalizedError, Equatable {
    case invalidQuery
    case httpStatus(Int)
    case unreadableResponse

    public var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "La consulta de búsqueda no es válida."
        case .httpStatus(let code):
            return "El buscador respondió con el código HTTP \(code)."
        case .unreadableResponse:
            return "La respuesta del buscador no se pudo interpretar."
        }
    }
}

public protocol WebSearching: Sendable {
    func search(query: String, maxResults: Int) async throws -> [WebSearchResult]
}

public final class MockWebSearcher: WebSearching, @unchecked Sendable {
    public var cannedResults: [WebSearchResult] = []
    public var shouldThrowError: Error?

    public init(cannedResults: [WebSearchResult] = []) {
        self.cannedResults = cannedResults
    }

    /// Sin resultados preparados devuelve una lista vacía: un doble de pruebas que
    /// fabrica resultados oculta exactamente el fallo que se estaba arreglando.
    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        if let err = shouldThrowError {
            throw err
        }
        return Array(cannedResults.prefix(maxResults))
    }
}

public final class SystemWebSearcher: WebSearching, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1") else {
            throw WebSearchError.invalidQuery
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0
        request.setValue("GemmaAssistant/1.0", forHTTPHeaderField: "User-Agent")

        // Los errores de red se propagan tal cual: el motivo real le sirve al agente.
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSearchError.unreadableResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebSearchError.httpStatus(httpResponse.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchError.unreadableResponse
        }

        var results: [WebSearchResult] = []

        if let heading = json["Heading"] as? String, !heading.isEmpty,
           let abstract = json["AbstractText"] as? String, !abstract.isEmpty,
           let sourceURL = json["AbstractURL"] as? String {
            results.append(WebSearchResult(title: heading, snippet: abstract, url: sourceURL))
        }

        if let related = json["RelatedTopics"] as? [[String: Any]] {
            for topic in related {
                if results.count >= maxResults { break }
                if let text = topic["Text"] as? String,
                   let firstURL = topic["FirstURL"] as? String {
                    results.append(WebSearchResult(title: text, snippet: text, url: firstURL))
                }
            }
        }

        // Una respuesta válida sin coincidencias son cero resultados, y eso es un
        // estado legítimo que el tool reporta aparte: no se rellena con nada.
        return Array(results.prefix(maxResults))
    }
}

public final class WebSearchService: Sendable {
    private let searcher: any WebSearching

    public init(searcher: any WebSearching = SystemWebSearcher()) {
        self.searcher = searcher
    }

    public func search(query: String, maxResults: Int = 3) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebSearchError.invalidQuery
        }
        return try await searcher.search(query: trimmed, maxResults: max(1, min(maxResults, 10)))
    }
}
