import Foundation
import JavaScriptCore

/// The renderer foreverlm.com draws a published Doc with, running on this Mac.
///
/// The Docs pane's Page view used to ask the site to draw the doc's current
/// text — `POST /api/publish/preview` on every open and every save — and
/// showed a spinner until the round trip landed: the TLS handshake, the
/// identity check behind the route, the render, the answer. The page is a pure
/// function of its Markdown, and the function is ours, so the app carries it:
/// `Web/PublishedPage/build.mjs` bundles `docs-site/website/publishing/`
/// (page.ts and markdown.ts, unchanged) into `App/PublishedPageResources/
/// published-page.js`, and this actor evaluates that bundle once in a
/// JavaScriptCore context and calls its `renderPublishedPage` for each page.
/// A long report renders in a few milliseconds, with no network and no
/// sign-in, from the same code the site runs — so the page in the app is the
/// page a reader sees. The preview route stays as the fallback when the
/// bundle cannot run (`DocPublishing.page`), and remains Web Studio's route.
///
/// A website test (`published-page-bundle.test.ts`) checks the bundle's
/// manifest against the renderer sources, so a renderer change that is not
/// rebuilt into the app fails the site's check instead of shipping two
/// renderers that disagree. Spec: docs/docs-design.md → Publishing.
actor PublishedPageRenderer {
    static let shared = PublishedPageRenderer()

    /// The bundle in the app: a folder resource, so the file is looked up by
    /// its folder first and by name alone for a bundle laid out flat.
    nonisolated static let bundledScriptURL: URL? = Bundle.main.url(
        forResource: "published-page", withExtension: "js", subdirectory: "PublishedPageResources"
    ) ?? Bundle.main.url(forResource: "published-page", withExtension: "js")

    /// The global the bundle defines and the function on it the site calls.
    static let globalName = "ForeverLMPublishedPage"
    static let renderFunctionName = "renderPublishedPage"
    static let versionName = "RENDERER_VERSION"

    enum Failure: LocalizedError, Equatable {
        /// No bundle in the app — the resource is missing or unreadable.
        case scriptMissing
        /// The bundle threw while being evaluated, or defines no renderer.
        case scriptFailed(String)
        /// The renderer threw for this input, or answered with no page.
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptMissing: return "The page renderer is missing from this build."
            case .scriptFailed(let detail): return "The page renderer could not start: \(detail)"
            case .renderFailed(let detail): return "The page could not be drawn: \(detail)"
            }
        }
    }

    private let scriptURL: URL?
    private let inlineScript: String?
    private var context: JSContext?

    /// The app's bundle by default; a test may point at another file, or at
    /// nil to stand in for a build that shipped without the resource.
    init(scriptURL: URL? = PublishedPageRenderer.bundledScriptURL) {
        self.scriptURL = scriptURL
        self.inlineScript = nil
    }

    /// A renderer from source, for tests of the host's handling.
    init(script: String) {
        self.scriptURL = nil
        self.inlineScript = script
    }

    /// The page for the input, as `renderPublishedPage` returns it.
    func render(_ input: DocPublishing.PreviewInput) throws -> String {
        let (context, module) = try loadedModule()
        guard let function = module.objectForKeyedSubscript(Self.renderFunctionName), function.isObject else {
            throw Failure.scriptFailed("\(Self.globalName).\(Self.renderFunctionName) is not a function")
        }
        let argument: [String: Any] = [
            "title": input.title,
            "markdown": input.markdown,
            "publishedAt": input.publishedAt,
            "updatedAt": input.updatedAt,
            "canonicalURL": input.canonicalURL,
            "sourceMarks": input.sourceMarks,
            "docLinks": input.docLinks,
        ]
        context.exception = nil
        let result = function.call(withArguments: [argument])
        if let exception = context.exception {
            context.exception = nil
            throw Failure.renderFailed(exception.toString() ?? "unknown error")
        }
        guard let result, result.isString, let html = result.toString(), !html.isEmpty else {
            throw Failure.renderFailed("the renderer returned no page")
        }
        return html
    }

    /// The context with the bundle evaluated, made on first use and kept: the
    /// bundle is evaluated once per app run, and every page after the first
    /// pays only for its own render.
    private func loadedModule() throws -> (JSContext, JSValue) {
        if let context, let module = context.objectForKeyedSubscript(Self.globalName), module.isObject {
            return (context, module)
        }
        let script: String
        if let inlineScript {
            script = inlineScript
        } else {
            guard let scriptURL, let loaded = try? String(contentsOf: scriptURL, encoding: .utf8) else {
                throw Failure.scriptMissing
            }
            script = loaded
        }
        guard let fresh = JSContext() else { throw Failure.scriptFailed("no JavaScript context") }
        fresh.exceptionHandler = { context, exception in
            context?.exception = exception
        }
        fresh.evaluateScript(script, withSourceURL: scriptURL ?? URL(string: "foreverlm://published-page.js"))
        if let exception = fresh.exception {
            throw Failure.scriptFailed(exception.toString() ?? "unknown error")
        }
        guard let module = fresh.objectForKeyedSubscript(Self.globalName), module.isObject else {
            throw Failure.scriptFailed("\(Self.globalName) is not defined")
        }
        context = fresh
        return (fresh, module)
    }
}
