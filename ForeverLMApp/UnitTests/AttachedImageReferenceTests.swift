import Foundation
import Testing
@testable import ForeverLM

@Suite("Attached image references")
struct AttachedImageReferenceTests {
    @Test("A dropped picture's reference round-trips through its URL and Markdown line")
    func roundTrip() {
        let id = AttachedImageReference.newID()
        let reference = AttachedImageReference(id: id)
        #expect(reference?.urlString == "foreverlm://image/attached/\(id)")
        #expect(AttachedImageReference(urlString: reference!.urlString) == reference)
        #expect(reference?.markdown(alt: "Screen Shot [2026]\n.png")
            == "![Screen Shot (2026) .png](foreverlm://image/attached/\(id))")
        #expect(reference?.markdown(alt: "  ") == "![Attached image](foreverlm://image/attached/\(id))")
    }

    @Test("Attached, generated and source references never claim each other's URLs")
    func grammarsAreDisjoint() {
        let attached = "foreverlm://image/attached/0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        #expect(AttachedImageReference(urlString: attached) != nil)
        #expect(GeneratedImageReference(urlString: attached) == nil)
        #expect(SourceImageReference(urlString: attached) == nil)

        let generated = "foreverlm://image/generated/0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        #expect(AttachedImageReference(urlString: generated) == nil)

        let source = "foreverlm://image/attached/page/3"
        #expect(AttachedImageReference(urlString: source) == nil)
        #expect(SourceImageReference(urlString: source)?.sourceID == "attached")

        #expect(AttachedImageReference(id: "../etc/passwd") == nil)
        #expect(AttachedImageReference(urlString: "foreverlm://image/attached/") == nil)
        #expect(AttachedImageReference(urlString: "https://example.com/image/attached/a1b2c3d4") == nil)
    }

    @Test("A message splits into the learner's words and the pictures they attached")
    func splitContent() throws {
        let first = try #require(AttachedImageReference(id: AttachedImageReference.newID()))
        let second = try #require(AttachedImageReference(id: AttachedImageReference.newID()))
        let content = """
        What does this graph show?

        \(first.markdown(alt: "graph.png"))

        \(second.markdown(alt: "table (2).jpg"))
        """
        let split = AttachedImageReference.split(content)
        #expect(split.text == "What does this graph show?")
        #expect(split.images.map(\.reference) == [first, second])
        #expect(split.images.map(\.alt) == ["graph.png", "table (2).jpg"])
        #expect(AttachedImageReference.containsReference(content))

        let picturesOnly = AttachedImageReference.split(first.markdown(alt: "shot.png"))
        #expect(picturesOnly.text.isEmpty)
        #expect(picturesOnly.images.count == 1)

        let plain = AttachedImageReference.split("Nothing attached, just ![a figure](foreverlm://image/src-1/page/2).")
        #expect(plain.images.isEmpty)
        #expect(plain.text == "Nothing attached, just ![a figure](foreverlm://image/src-1/page/2).")
        #expect(!AttachedImageReference.containsReference(plain.text))
    }

    @Test("Text-only rendering names each picture where its line was")
    @MainActor
    func textOnly() throws {
        let reference = try #require(AttachedImageReference(id: AttachedImageReference.newID()))
        let content = "Look:\n\n\(reference.markdown(alt: "cell.png"))\n\nWhat is the organelle at the top?"
        #expect(AttachedImageReference.textOnly(content)
            == "Look:\n\n[Attached image: cell.png]\n\nWhat is the organelle at the top?")
        #expect(AttachedImageReference.textOnly(content) { "<\($0.alt)>" } == "Look:\n\n<cell.png>\n\nWhat is the organelle at the top?")
        #expect(AttachedImageReference.textOnly("no pictures") == "no pictures")

        // The learner's bubble, copied transcripts and compacted history all
        // read through this; only the raw content keeps the lines.
        #expect(ReviewSessionManager.displayableMessageContent(role: .user, content: content)
            == "Look:\n\n[Attached image: cell.png]\n\nWhat is the organelle at the top?")
    }

    @Test("The store answers from memory before the disk and finds a written picture by id")
    func storeRoundTrip() throws {
        let id = AttachedImageReference.newID()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let image = AttachedImage(data: bytes, mediaType: "image/png")

        AttachedImageStore.stage(image, id: id)
        #expect(AttachedImageStore.cached(id: id) == image)
        #expect(AttachedImageStore.read(id: id) == image, "staged bytes resolve before any write")
        AttachedImageStore.unstage(id: id)
        #expect(AttachedImageStore.cached(id: id) == nil)
        #expect(AttachedImageStore.read(id: id) == nil)

        let relative = try AttachedImageStore.write(image, id: id)
        defer {
            try? FileManager.default.removeItem(atPath: StorageService.absoluteSourcePath(relative))
            AttachedImageStore.unstage(id: id)
        }
        #expect(relative == "Attached Images/\(id).png")
        AttachedImageStore.unstage(id: id)
        #expect(AttachedImageStore.read(id: id) == image, "a written picture is found on disk after memory forgets it")
        #expect(AttachedImageStore.read(id: AttachedImageReference.newID()) == nil)
        #expect(AttachedImageStore.read(id: "../\(id)") == nil)
    }

    @Test("The transcript resolves an attached picture from the store without an article")
    @MainActor
    func transcriptResolvesAttachedPicture() async throws {
        let id = AttachedImageReference.newID()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        AttachedImageStore.stage(AttachedImage(data: bytes, mediaType: "image/png"), id: id)
        defer { AttachedImageStore.unstage(id: id) }
        let reference = try #require(AttachedImageReference(id: id))

        var askedForArticle = false
        let resolved = await ChatSourceImage.resolved(token: reference.urlString) { _ in
            askedForArticle = true
            return nil
        }
        #expect(resolved?.data == bytes)
        #expect(resolved?.mediaType == "image/png")
        #expect(!askedForArticle)

        let missing = await ChatSourceImage.resolved(token: "foreverlm://image/attached/\(AttachedImageReference.newID())") { _ in nil }
        #expect(missing == nil)
    }

    @Test("A learner turn carries its pictures as image parts and names the ones it cannot send")
    func userTurn() throws {
        let held = try #require(AttachedImageReference(id: AttachedImageReference.newID()))
        let missing = try #require(AttachedImageReference(id: AttachedImageReference.newID()))
        let bytes = Data([1, 2, 3])
        let content = "Compare these.\n\n\(held.markdown(alt: "a.png"))\n\n\(missing.markdown(alt: "b.png"))"
        let lookup: (String) -> AttachedImage? = { id in
            id == held.id ? AttachedImage(data: bytes, mediaType: "image/png") : nil
        }

        guard case .user(let text, let images) = ReviewSessionManager.userTurn(content: content, imageForID: lookup) else {
            Issue.record("expected a user turn")
            return
        }
        #expect(images == [AIChatImage(data: bytes, mediaType: "image/png")])
        #expect(text == "Compare these.\n[Attached image \u{201C}b.png\u{201D} is not available on this device]")

        guard case .user(let textOnly, let none) = ReviewSessionManager.userTurn(
            content: content, imagesReadable: false, imageForID: lookup
        ) else {
            Issue.record("expected a user turn")
            return
        }
        #expect(none.isEmpty)
        #expect(textOnly.contains("the selected model reads text only"))
        #expect(!textOnly.contains("foreverlm://image"))

        guard case .user(let plain, let plainImages) = ReviewSessionManager.userTurn(content: "Just words", imageForID: lookup) else {
            Issue.record("expected a user turn")
            return
        }
        #expect(plain == "Just words")
        #expect(plainImages.isEmpty)

        let routed = ReviewSessionManager.textOnlyProviderMessages([
            (role: "user", content: content),
            (role: "assistant", content: "\(held.markdown(alt: "echo"))"),
        ])
        #expect(!routed[0].content.contains("foreverlm://image"))
        #expect(routed[0].content.contains("this route sends text only"))
        #expect(routed[1].content == held.markdown(alt: "echo"), "assistant text is never rewritten")
    }

    @Test("A model known to read images, or a message without one, is never refused")
    func visionRefusalOnlyForTextOnlyModels() throws {
        let reference = try #require(AttachedImageReference(id: AttachedImageReference.newID()))
        let anthropic = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-opus-5")
        #expect(ReviewSessionManager.visionRefusal(for: anthropic, latestUserMessage: reference.markdown(alt: "x.png")) == nil)

        let unknown = AITaskConfig(provider: .openRouter, apiKey: "k", model: "some/unlisted-model")
        #expect(ReviewSessionManager.visionRefusal(for: unknown, latestUserMessage: reference.markdown(alt: "x.png")) == nil,
                "an unknown capability sends the request and lets the provider answer")
        #expect(ReviewSessionManager.visionRefusal(for: unknown, latestUserMessage: "no picture here") == nil)
        #expect(ReviewSessionManager.visionRefusal(for: unknown, latestUserMessage: nil) == nil)
    }
}

/// The frame of the moment a question beside a video was asked at, as the
/// model receives it (`VideoMomentFrames`, `ReviewSessionManager.userTurn`).
@Suite("Video moment frames in a learner turn")
struct VideoMomentFrameTurnTests {
    private let frame = SourceImageReference(sourceID: "src-talk", location: .moment(1611))
    private let slide = SourceImageReference(sourceID: "src-talk", location: .slide(17))

    @Test("A moment's frame line leaves the text and goes as a picture; a slide line is not a moment")
    func splitTakesOnlyMomentLines() {
        let content = "What is this?\n\n\(frame.markdown(alt: "Talk at 26:51"))\n\n\(slide.markdown(alt: "Slide 17"))"
        let split = VideoMomentFrames.split(content)
        #expect(split.frames == [VideoMomentFrames.Occurrence(reference: frame, alt: "Talk at 26:51")])
        #expect(split.text == "What is this?\n\n\(slide.markdown(alt: "Slide 17"))")
        #expect(VideoMomentFrames.split("Just words").text == "Just words")
        #expect(VideoMomentFrames.split("Just words").frames.isEmpty)

        let cropped = SourceImageReference(
            sourceID: "src-talk",
            location: .moment(1611),
            crop: PaperFigureRect(x: 0.5, y: 0.1, width: 0.5, height: 0.8)
        )
        #expect(VideoMomentFrames.split(cropped.markdown(alt: "detail")).frames.first?.reference == cropped)
    }

    @Test("The frame goes to the model when held, and is named when it is not or cannot be read")
    func userTurnSendsTheFrame() {
        let bytes = Data([9, 8, 7])
        let content = "What does he mean?\n\n<video_moment>\nOn screen at 26:51:\n\(frame.markdown(alt: "Talk at 26:51"))\n</video_moment>"
        let held: (SourceImageReference) -> AttachedImage? = { $0 == frame ? AttachedImage(data: bytes, mediaType: "image/jpeg") : nil }

        guard case .user(let text, let images) = ReviewSessionManager.userTurn(content: content, momentFrame: held) else {
            Issue.record("expected a user turn")
            return
        }
        #expect(images == [AIChatImage(data: bytes, mediaType: "image/jpeg")])
        #expect(!text.contains("foreverlm://image"))
        #expect(text.contains("On screen at 26:51:"))

        guard case .user(let missingText, let none) = ReviewSessionManager.userTurn(content: content, momentFrame: { _ in nil }) else {
            Issue.record("expected a user turn")
            return
        }
        #expect(none.isEmpty)
        #expect(missingText.contains("[Frame \u{201C}Talk at 26:51\u{201D} is not available on this device]"))

        guard case .user(let textOnly, let noImages) = ReviewSessionManager.userTurn(
            content: content, imagesReadable: false, momentFrame: held
        ) else {
            Issue.record("expected a user turn")
            return
        }
        #expect(noImages.isEmpty)
        #expect(textOnly.contains("the selected model reads text only"))

        let routed = ReviewSessionManager.textOnlyProviderMessages([(role: "user", content: content)])
        #expect(!routed[0].content.contains("foreverlm://image"))
        #expect(routed[0].content.contains("this route sends text only"))
    }

    @Test("A frame staged in memory is the one the turn reads")
    func stagedFrameIsCached() {
        let reference = SourceImageReference(sourceID: "src-staged-\(UUID().uuidString)", location: .moment(42))
        #expect(VideoMomentFrames.cached(reference) == nil)
        VideoMomentFrames.stage(AttachedImage(data: Data([1]), mediaType: "image/jpeg"), for: reference)
        #expect(VideoMomentFrames.cached(reference)?.data == Data([1]))
    }
}
