#if os(macOS)
import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    /// A made picture was drawn again with another model. `userInfo` carries
    /// `GeneratedImageRedraw.replacedKey` (the version ids it is now shown in
    /// place of), `imageIDKey` (the image) and `versionKey` (the redraw), so
    /// every chat line, card and gallery that showed the picture shows it anew.
    static let generatedImageRedrawn = Notification.Name("ForeverLM.generatedImageRedrawn")
}

/// Drawing a picture ForeverLM keeps — a quiz question's, a walkthrough
/// card's, one a chat drew — again from the prompt that made it, with another
/// image model. The product owner, 2026-09-29: "for images in a quiz or walkthrough, we
/// should be able to right click and see which model generated them; then
/// regenerate them with a different model (e.g. if they are bad quality)".
///
/// A redraw is the image's next version (`GeneratedImageStore.storeRedraw`),
/// and the version it redraws is marked replaced by it, so every chat line
/// and card that showed the old picture shows the new one. The quizzes that
/// pinned it are pointed at the redraw, so the Course record carries it to
/// the learner's other Macs (`CourseQuizPicturePackage`), where the version
/// it replaced is marked the same way when it arrives. A walk that shows it
/// keeps naming the id it named, so its record does not change; the store's
/// `generatedImagesChanged` notice has the sync engine re-send it, and the
/// Source record carries the redraw (`WalkthroughPicturePackage`).
enum GeneratedImageRedraw {
    static let replacedKey = "replaced"
    static let imageIDKey = "imageID"
    static let versionKey = "version"

    struct Outcome: Sendable {
        /// The redraw, as stored.
        let listing: GeneratedImageStore.Listing
        /// Every version it is now shown in place of.
        let replacedIDs: [String]
        /// The quizzes whose questions now pin it.
        let quizIDs: [String]
        let modelName: String
    }

    enum Failure: LocalizedError, Equatable {
        case notHeld

        var errorDescription: String? {
            switch self {
            case .notHeld: return "This Mac does not hold the picture."
            }
        }
    }

    // MARK: What the menu says

    /// Where the picture came from, as the menu's first line says it.
    static func madeByLine(_ details: GeneratedImageStore.Details?) -> String {
        switch details?.origin {
        case .saved?:
            return details?.model.map { "Made with \($0), saved from elsewhere" } ?? "Saved from elsewhere"
        case .screenshot?:
            return "Screenshot"
        case .drawn?, nil:
            return details?.model.map { "Drawn by \($0)" } ?? "Model not recorded"
        }
    }

    /// Whether the picture can be drawn again: one made from a prompt that
    /// was kept with it.
    static func canRedraw(_ details: GeneratedImageStore.Details?) -> Bool {
        guard let details else { return false }
        return details.origin != .screenshot && !details.text.isEmpty
    }

    /// The models Redraw With offers: the Settings › Images choice first,
    /// then that pane's Suggested list (one model per maker) as the pane
    /// shows it, each pick as its family's newest release, each once and
    /// only while OpenRouter's directory serves it. Empty until the
    /// directory has been read.
    static func offeredModels(
        settingsChoice: String,
        suggested: [String] = ImageGenerationCatalog.suggestedModelIDs,
        directory: [ImageGenerationModel]
    ) -> [ImageGenerationModel] {
        let current = AIModelCatalog.newestReleases(
            of: suggested,
            listed: AIModelCatalog.listingDates(directory, slug: \.id, listedAt: \.createdAt)
        )
        var seen = Set<String>()
        return ([settingsChoice] + current).compactMap { id in
            let canonical = ImageGenerationCatalog.canonicalID(id)
            guard seen.insert(canonical).inserted else { return nil }
            return directory.first { $0.id == canonical }
        }
    }

    /// The model's name with what a picture costs on it, as the menus list
    /// it: the price a promotion leaves when one runs, as Settings › Images
    /// shows it. The name alone until the prices have been read.
    @MainActor
    static func menuTitle(for model: ImageGenerationModel) -> String {
        guard var price = model.price else { return model.name }
        if !price.isFree, let promotion = OpenRouterPromotions.current[model.id.lowercased()] {
            price = price.mapped(promotion.effectiveRate(fromList:))
        }
        return "\(model.name) · \(price.label)"
    }

    /// Whether `model` drew the picture: by its slug, or for a picture
    /// stored before slugs were kept, by the name it was stored under.
    static func drew(_ details: GeneratedImageStore.Details?, _ model: ImageGenerationModel) -> Bool {
        guard let details, details.origin == .drawn else { return false }
        if let id = details.modelID { return ImageGenerationCatalog.canonicalID(id) == model.id }
        return details.model == model.name
    }

    /// The shape nearest the picture's own frame, so the redraw fills the
    /// place the old one did.
    static func shape(width: Int, height: Int) -> ImageGenerationCatalog.Shape {
        guard width > 0, height > 0 else { return .square }
        let target = log(Double(width) / Double(height))
        func distance(_ shape: ImageGenerationCatalog.Shape) -> Double {
            abs(log(ImageGenerationCatalog.Shape.ratio(shape.aspectRatio) ?? 1) - target)
        }
        return ImageGenerationCatalog.Shape.allCases.min { distance($0) < distance($1) } ?? .square
    }

    /// The quiz with every question that pinned one of `ids` pinning `url`
    /// instead, its caption, placement and brief kept; nil when none did.
    static func repointing(_ quiz: CourseQuiz, from ids: Set<String>, to url: String, at date: Date = Date()) -> CourseQuiz? {
        var quiz = quiz
        var changed = false
        for index in quiz.questions.indices {
            guard let picture = quiz.questions[index].picture,
                  let id = picture.storedImageID, ids.contains(id) else { continue }
            quiz.questions[index].picture = picture.drawn(as: url)
            changed = true
        }
        guard changed else { return nil }
        quiz.updatedAt = date
        return quiz
    }

    // MARK: Drawing it again

    private struct Plan: Sendable {
        let shownID: String
        let prompt: String
        let shape: ImageGenerationCatalog.Shape
        let showing: [String]
    }

    /// Draws the picture `id` names — as shown, so its latest redraw — again
    /// with `model`, from the prompt kept with it, at its own shape, and
    /// stores the redraw in its place. A quiz that pins it is billed as a
    /// quiz picture, keeps it as compact as its other drawings, and is
    /// pointed at it. Throws before anything is spent when the picture is
    /// not held or has no prompt.
    static func redraw(
        id: String,
        with model: ImageGenerationModel,
        prompt edited: String? = nil,
        usageTask: String,
        storage: StorageService
    ) async throws -> Outcome {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let plan = try await Task.detached(priority: .userInitiated) { () throws -> Plan in
            let shown = GeneratedImageStore.shownVersion(for: wanted)
            guard let group = GeneratedImageStore.group(containing: shown),
                  let listing = group.versions.first(where: { $0.id == shown }) else { throw Failure.notHeld }
            guard let details = listing.details, Self.canRedraw(details) else {
                throw GeneratedImageStore.RedrawFailure.noPrompt
            }
            let size = GeneratedImageStore.pixelSize(ofFileAt: listing.path)
            return Plan(
                shownID: shown,
                prompt: details.text,
                shape: size.map { Self.shape(width: $0.width, height: $0.height) } ?? .square,
                showing: group.versions(showingAs: shown)
            )
        }.value

        // The prompt as the learner left it in the dialog, else the one kept.
        let trimmedEdit = edited?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = trimmedEdit.isEmpty ? plan.prompt : trimmedEdit
        let showing = Set(plan.showing)
        let quizzes = try await storage.loadCourseQuizzes(mentioning: plan.showing).filter { quiz in
            quiz.questions.contains { question in question.picture?.storedImageID.map(showing.contains) == true }
        }
        let resolved = try await ImageGenerationDirectory.resolve(model)
        let quiz = quizzes.first
        let drawn = try await ManagedImageGeneration.generate(
            prompt: prompt,
            model: resolved,
            shape: plan.shape,
            quality: .medium,
            usageTask: quiz == nil ? usageTask : "course_quiz_picture",
            source: quiz.map { AIUsageSource(id: $0.id, type: "course_quiz", title: $0.title) }
        )
        // A quiz's pictures ride its Course record as one package, so one a
        // quiz shows is kept at the size of the drawings beside it.
        let kept = quizzes.isEmpty ? drawn : CourseQuizGeneratorService.compactDrawing(drawn)
        let modelName = resolved.name
        let modelID = resolved.id
        let shownID = plan.shownID
        let stored = try await Task.detached(priority: .userInitiated) {
            try GeneratedImageStore.storeRedraw(kept, replacing: shownID, model: modelName, modelID: modelID, prompt: prompt)
        }.value

        let url = CourseQuizPicture.storedImageURL(id: stored.id)
        var repointed: [String] = []
        for quiz in quizzes {
            // Read again: a rewrite that landed while the picture was drawn
            // keeps whatever it put in the picture's place.
            guard let current = try await storage.loadCourseQuiz(quiz.id),
                  let updated = repointing(current, from: showing, to: url) else { continue }
            try await storage.saveCourseQuiz(updated)
            repointed.append(quiz.id)
        }
        return Outcome(listing: stored, replacedIDs: plan.showing, quizIDs: repointed, modelName: modelName)
    }

    // MARK: The Redraw button's dialog

    /// The Redraw button: the prompt that went into the picture, to change as
    /// wanted, and the model to draw it with and what that costs. `redraw`
    /// runs on Redraw with the prompt as it stands. The directory is read
    /// first when this launch has not, and the prices fill in as they arrive.
    @MainActor
    static func presentDialog(
        for listing: GeneratedImageStore.Listing,
        over window: NSWindow,
        redraw: @escaping (ImageGenerationModel, String) -> Void
    ) {
        Task { @MainActor in
            if ImageGenerationCatalog.models.isEmpty {
                _ = try? await ImageGenerationDirectory.models()
            }
            @MainActor func offered() -> [ImageGenerationModel] {
                offeredModels(settingsChoice: MacImageGenerationSettings.model.id, directory: ImageGenerationCatalog.models)
            }
            let models = offered()
            guard !models.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "Couldn't read OpenRouter's image models"
                alert.informativeText = "Check your connection and try Redraw again."
                alert.beginSheetModal(for: window, completionHandler: nil)
                return
            }

            let alert = NSAlert()
            alert.messageText = "Redraw the picture"
            alert.informativeText = "This is the prompt it was drawn from. Change it to say what to fix, then pick a model."
            alert.addButton(withTitle: "Redraw")
            alert.addButton(withTitle: "Cancel")

            let width: CGFloat = 440
            let promptLabel = NSTextField(labelWithString: "Prompt")
            promptLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 150))
            textView.isRichText = false
            textView.allowsUndo = true
            textView.font = .systemFont(ofSize: NSFont.systemFontSize)
            textView.textContainerInset = NSSize(width: 4, height: 6)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.string = listing.details?.text ?? ""
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 150))
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

            let modelLabel = NSTextField(labelWithString: "Model")
            modelLabel.font = promptLabel.font
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            @MainActor func fill(_ models: [ImageGenerationModel]) {
                let chosen = popup.indexOfSelectedItem
                popup.removeAllItems()
                for model in models {
                    popup.addItem(withTitle: menuTitle(for: model))
                }
                popup.selectItem(at: chosen >= 0 && chosen < models.count ? chosen : 0)
            }
            fill(models)

            let stack = NSStackView(views: [promptLabel, scroll, modelLabel, popup])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.frame = NSRect(x: 0, y: 0, width: width, height: 230)
            alert.accessoryView = stack
            alert.window.initialFirstResponder = textView

            // The prices cost a request each, so the dialog opens on the
            // names and the figures join them when the directory has them.
            let pricing = Task { @MainActor in
                guard (try? await ImageGenerationDirectory.modelsWithPrices()) != nil else { return }
                let current = offered()
                if current.map(\.id) == models.map(\.id) { fill(current) }
            }
            alert.beginSheetModal(for: window) { response in
                pricing.cancel()
                guard response == .alertFirstButtonReturn else { return }
                let index = popup.indexOfSelectedItem
                let latest = offered()
                guard let model = latest.first(where: { $0.id == models[safe: index]?.id }) ?? models[safe: index] else { return }
                redraw(model, textView.string)
            }
        }
    }

    // MARK: The menu in a web view

    /// The picture's lines for a menu WebKit builds (a chat's), where SwiftUI
    /// cannot reach: what made it, then Redraw With and the models, or that
    /// it is being redrawn. `keep` holds each item's target, since
    /// `NSMenuItem.target` is weak. `flat` lists the models directly, for the
    /// Redraw button's own menu, where a "Redraw With" step would be one hover
    /// too many.
    @MainActor
    static func menuItems(
        for listing: GeneratedImageStore.Listing,
        flat: Bool = false,
        redraw: @escaping (ImageGenerationModel) -> Void,
        keep: (MenuActionTarget) -> Void
    ) -> [NSMenuItem] {
        let details = listing.details
        let madeBy = NSMenuItem(title: madeByLine(details), action: nil, keyEquivalent: "")
        madeBy.isEnabled = false
        var items = [madeBy]
        if let model = GeneratedImageRedrawCenter.shared.inFlight[listing.id] {
            let busy = NSMenuItem(title: "Redrawing with \(model)…", action: nil, keyEquivalent: "")
            busy.isEnabled = false
            items.append(busy)
        } else if canRedraw(details) {
            let submenu = flat ? nil : NSMenu(title: "Redraw With")
            var modelItems: [NSMenuItem] = []
            let models = offeredModels(settingsChoice: MacImageGenerationSettings.model.id, directory: ImageGenerationCatalog.models)
            if models.isEmpty {
                ImageGenerationDirectory.warm()
                let loading = NSMenuItem(title: "Loading image models…", action: nil, keyEquivalent: "")
                loading.isEnabled = false
                modelItems.append(loading)
            }
            for model in models {
                let target = MenuActionTarget { redraw(model) }
                keep(target)
                let item = NSMenuItem(title: menuTitle(for: model), action: #selector(MenuActionTarget.fire), keyEquivalent: "")
                item.target = target
                item.state = drew(details, model) ? .on : .off
                modelItems.append(item)
            }
            if let submenu {
                for item in modelItems { submenu.addItem(item) }
                let parent = NSMenuItem(title: "Redraw With", action: nil, keyEquivalent: "")
                parent.submenu = submenu
                items.append(parent)
            } else {
                items.append(.separator())
                let heading = NSMenuItem(title: "Redraw With", action: nil, keyEquivalent: "")
                heading.isEnabled = false
                items.append(heading)
                items.append(contentsOf: modelItems)
            }
        }
        return items
    }
}

/// The redraws in flight, for the menus that say a picture is being redrawn
/// and the cards that dim it, and the one place a redraw reports from: the
/// picture changes where it shows, the quizzes that pin it are read again,
/// and a failure is said in the Studio's banner.
@MainActor @Observable
final class GeneratedImageRedrawCenter {
    static let shared = GeneratedImageRedrawCenter()

    /// The model each picture is being redrawn with, by the version id the
    /// menu named.
    private(set) var inFlight: [String: String] = [:]

    func redraw(
        id: String,
        with model: ImageGenerationModel,
        prompt: String? = nil,
        usageTask: String,
        vm: StudioViewModel?
    ) async {
        let key = id.lowercased()
        guard inFlight[key] == nil else { return }
        inFlight[key] = model.name
        defer { inFlight[key] = nil }
        do {
            let outcome = try await GeneratedImageRedraw.redraw(
                id: key,
                with: model,
                prompt: prompt,
                usageTask: usageTask,
                storage: vm?.storage ?? StorageService()
            )
            ChatSourceImage.forgetGenerated(ids: outcome.replacedIDs + [key])
            NotificationCenter.default.post(name: .generatedImageRedrawn, object: nil, userInfo: [
                GeneratedImageRedraw.replacedKey: outcome.replacedIDs + [key],
                GeneratedImageRedraw.imageIDKey: outcome.listing.imageID,
                GeneratedImageRedraw.versionKey: outcome.listing.id,
            ])
            if !outcome.quizIDs.isEmpty { await vm?.refreshCourseQuizzes() }
            vm?.showToast("Redrew the picture with \(outcome.modelName).")
        } catch {
            let message = "Couldn't redraw the picture with \(model.name): \(error.localizedDescription)"
            if let vm {
                vm.showToast(message)
            } else {
                let alert = NSAlert()
                alert.messageText = message
                alert.runModal()
            }
        }
    }
}

/// The picture's lines in a SwiftUI context menu — a walkthrough card's: what
/// made it, then Redraw With and the models, the one that drew it checked, or
/// that it is being redrawn.
struct GeneratedImageRedrawMenuItems: View {
    let listing: GeneratedImageStore.Listing
    let redraw: (ImageGenerationModel) -> Void

    var body: some View {
        let details = listing.details
        Text(GeneratedImageRedraw.madeByLine(details))
        if let model = GeneratedImageRedrawCenter.shared.inFlight[listing.id] {
            Text("Redrawing with \(model)…")
        } else if GeneratedImageRedraw.canRedraw(details) {
            let models = GeneratedImageRedraw.offeredModels(
                settingsChoice: MacImageGenerationSettings.model.id,
                directory: ImageGenerationCatalog.models
            )
            Menu("Redraw With") {
                if models.isEmpty {
                    Text("Loading image models…")
                }
                ForEach(models) { model in
                    Button {
                        redraw(model)
                    } label: {
                        if GeneratedImageRedraw.drew(details, model) {
                            Label(GeneratedImageRedraw.menuTitle(for: model), systemImage: "checkmark")
                        } else {
                            Text(GeneratedImageRedraw.menuTitle(for: model))
                        }
                    }
                }
            }
        }
    }
}
#endif
