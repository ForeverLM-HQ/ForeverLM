import Foundation

// MARK: - Images: pictures made from a prompt, kept with their prompts

/// `list_images`, `get_image`, `generate_image`, `save_image`, `rename_image`
/// and `delete_image`: the pictures a notebook's Studio lists, over MCP, so a
/// picture made in ChatGPT or Claude is kept beside the ones the in-app chat
/// draws (product owner,
/// 2026-09-22: "Make sure you also expose all of those things in the MCP,
/// because I might want to generate the image in ChatGPT or Claude").
///
/// The store is `GeneratedImageStore`: one file per version under the content
/// root, its title, prompt, model, origin and image id in the file's own XMP. An image
/// iterated on is one image in versions — `revises` names the image a new
/// picture is the next version of — and every tool here speaks in images, each
/// once at its latest version, with the versions inside. Nothing here touches
/// `knowledge.db`, so every tool is exempt from the store gate.
extension MCPDataStore {

    static let imageToolNames: Set<String> = [
        "list_images", "get_image", "generate_image", "save_image", "rename_image", "delete_image",
    ]

    /// The largest picture `save_image` takes, decoded.
    static let maxSavedImageBytes = 20 * 1024 * 1024

    static var imageToolDefs: [MCPToolDef] {
        let imageArgument: [String: Any] = [
            "type": "string",
            "description": "The image: its image_id from list_images, the id of any of its versions, or its foreverlm://image/generated/<id> address or Markdown line.",
        ]
        let titleArgument: [String: Any] = [
            "type": "string",
            "description": "Required for a new image: two to six words naming it, as a file is named — \"Forward vs reverse electron transport\", not the prompt's opening. Its Notebook's Studio lists the image under it. With revises, omit it to keep the image's title.",
        ]
        let revisesArgument: [String: Any] = [
            "type": "string",
            "description": "Optional. When this picture is a change to one already kept — \"make it bluer\", a second attempt at the same idea — the image_id (or any version's id) of that image. The picture is then stored as its next version, and the image is listed once, at this version. Omit for a new image.",
        ]
        let notebookArgument: [String: Any] = [
            "type": "string",
            "description": "Optional. The Notebook (from list_notebooks) a new image lives in. The app lists a picture only in its Notebook's Studio, so pass the Notebook the learner is working in; an image kept in no Notebook is found only by list_images and wherever it is shown. A revision keeps its image's Notebook. Refused, before anything is made, for an archived Notebook or a team's the learner can only read.",
        ]
        return [
            MCPToolDef(
                name: "list_images",
                description: "List the images ForeverLM keeps on this Mac — drawn by its chat or generate_image, or made in ChatGPT, Claude or another tool and saved with save_image — most recently changed first, each once at its latest version: its title, image_id, the prompt it was made from, the model, how many versions it has and their ids, its file path, and its foreverlm://image/generated/<id> line for a ForeverLM chat or Doc. Browser screenshots are not listed. Use it before making a picture the learner may already have, and to find the image_id that get_image, revises and delete_image take.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Optional. Words every listed image's title or prompt (any version's) must contain."],
                        "limit": ["type": "integer", "description": "Optional. How many images to list; 20 by default, at most 100."],
                        "notebook_id": ["type": "string", "description": "Optional. Only the images that live in this Notebook (from list_notebooks): those drawn or kept there. A picture inside a course quiz or a walkthrough belongs to that, not to a Notebook of its own."],
                    ],
                ]
            ),
            MCPToolDef(
                name: "get_image",
                description: "Show one kept image: the picture itself, its title, the prompt it was made from, its model and date, and its versions (newest first, each with its id and prompt). Returns the latest version unless version names another. Use it to look at a picture before changing it, or to hand its prompt to another image model.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "image": imageArgument,
                        "version": ["type": "integer", "description": "Optional. The version number to show (1 is the first); the latest by default. A later version's own id passed as image shows that version."],
                    ],
                    "required": ["image"],
                ]
            ),
            MCPToolDef(
                name: "generate_image",
                description: "Draw a picture with ForeverLM's image model (the learner's image model, images.model in get_app_settings) and keep it with its prompt, in the Notebook notebook_id names, whose Studio lists it; returns the picture and its ids. Each call is billed to the learner's own OpenRouter key, so call it only when the learner asks ForeverLM to draw it — a picture you or another tool can make yourself is kept with save_image instead, at no charge. Write prompt as a complete description of the picture: subject, composition, style, mood, and whether it contains any text, and give a new picture a short title. Pass revises to change a picture already kept: that version (the latest, when revises names the image) is sent to the model to edit, and the result becomes the image's next version — write prompt as the edit, what to change and what must stay.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string", "description": "Full description of the picture to draw; with revises, the edit — what to change and what must stay the same."],
                        "title": titleArgument,
                        "shape": [
                            "type": "string",
                            "enum": ImageGenerationCatalog.Shape.allCases.map(\.rawValue),
                            "description": "square (default), landscape, or portrait.",
                        ] as [String: Any],
                        "quality": [
                            "type": "string",
                            "enum": ImageGenerationCatalog.Quality.allCases.map(\.rawValue),
                            "description": "medium (default); low for a quick draft, high only when asked for the best possible picture.",
                        ] as [String: Any],
                        "revises": revisesArgument,
                        "notebook_id": notebookArgument,
                    ] as [String: Any],
                    "required": ["prompt"],
                ]
            ),
            MCPToolDef(
                name: "save_image",
                description: "Keep a picture made elsewhere — by ChatGPT, Claude, an image model you called, or a file the learner has — in ForeverLM with the prompt it was made from, in the Notebook notebook_id names, so it can be found and used again. Always pass the prompt: a picture is never kept without one; a new image also needs a short title. Pass the picture as image_base64 (the bytes; a data: URL is accepted) or local_path (a file on this Mac, read by the Mac so the bytes do not travel through the call); PNG and JPEG are kept as they are, any other image format is kept as a lossless PNG. Pass revises when it is a new version of an image already kept — the learner iterating on the same picture — so that image is listed once, at its newest version.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string", "description": "The prompt the picture was made from, in full. For a picture made without one, a sentence saying what it shows."],
                        "title": titleArgument,
                        "image_base64": ["type": "string", "description": "The picture's bytes as base64 (at most 20 MB decoded). Pass exactly one of image_base64 and local_path."],
                        "local_path": ["type": "string", "description": "A picture file on this Mac to keep. Pass exactly one of image_base64 and local_path."],
                        "model": ["type": "string", "description": "Optional. What made it, as the learner would say it: \"ChatGPT (GPT Image 2)\", \"Claude\", \"Midjourney v8\"."],
                        "revises": revisesArgument,
                        "notebook_id": notebookArgument,
                    ],
                    "required": ["prompt"],
                ]
            ),
            MCPToolDef(
                name: "rename_image",
                description: "Give a kept image a new title — the name its Notebook's Studio lists it under, as the learner renames it there. Every version takes the title; the pictures, prompts and dates are left as they are.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "image": imageArgument,
                        "title": ["type": "string", "description": "The new title: a few words naming the picture."],
                    ],
                    "required": ["image", "title"],
                ]
            ),
            MCPToolDef(
                name: "delete_image",
                description: "Move a kept image to the Trash: every version, or only the version named. Confirm with the learner first. A chat or Doc that showed it then says the picture is not on this Mac.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "image": imageArgument,
                        "version": ["type": "integer", "description": "Optional. Only this version number; the image keeps its others. Omit to remove the whole image."],
                    ],
                    "required": ["image"],
                ]
            ),
        ]
    }

    /// Runs an image tool; nil for any other name.
    func executeImageTool(name: String, arguments: [String: Any]) async -> MediaToolResult? {
        switch name {
        case "list_images": return await listImages(arguments: arguments)
        case "get_image": return await getImage(arguments: arguments)
        case "generate_image": return await generateImage(arguments: arguments)
        case "save_image": return await saveImage(arguments: arguments)
        case "rename_image": return await renameImage(arguments: arguments)
        case "delete_image": return await deleteImage(arguments: arguments)
        default: return nil
        }
    }

    // MARK: list_images

    func listImages(arguments: [String: Any]) async -> MediaToolResult {
        let query = Self.trimmedOrNil(arguments["query"] as? String)
        let limit = min(max(Self.intArgument(arguments["limit"]) ?? 20, 1), 100)
        // notebook_id: only the images that live in that notebook — a filed
        // thing, by the Notebook its first version was made in
        // (`NotebookMembership`). Checked through the storage actor.
        let notebook: NotebookMembership?
        do {
            notebook = try await notebookMembershipForListing(notebookID: arguments["notebook_id"] as? String)
        } catch {
            return .failure(error.localizedDescription)
        }
        // Screen record mode (admin only): an image carries no source, so
        // only one first drawn during the take, kept on the mode's image
        // list, is listed. Nil scope lists every image, as before.
        let screenScope = screenRecordScope()
        let groups = await Task.detached(priority: .userInitiated) { GeneratedImageStore.imageGroups() }.value
            .filter { group in
                if let notebook, !notebook.containsFiled([group.notebookID]) { return false }
                guard let screenScope else { return true }
                return screenScope.allowsImage(id: group.imageID, createdAt: group.versions.map(\.createdAt).min())
            }
        var text = GeneratedImageStore.catalog(groups, query: query, limit: limit, forMCP: true)
        if let notebook, groups.isEmpty {
            text = "No image lives in Notebook \(notebook.notebookID) yet."
        }
        return MediaToolResult(text: text, images: [], isError: false)
    }

    // MARK: get_image

    func getImage(arguments: [String: Any]) async -> MediaToolResult {
        guard let requested = ReviewSessionManager.imageID(fromArgument: arguments["image"]) else {
            return .failure("get_image needs an image: its image_id from list_images.")
        }
        let version = Self.intArgument(arguments["version"])
        let found = await Task.detached(priority: .userInitiated) { () -> (GeneratedImageStore.ImageGroup, GeneratedImageStore.Listing, Data)? in
            guard let group = GeneratedImageStore.group(containing: requested) else { return nil }
            let chosen: GeneratedImageStore.Listing?
            if let version {
                chosen = group.versions.first { $0.version == version }
            } else if requested == group.imageID {
                // The image's id is its first version's file id too; named
                // as the image, it means the image as it is now.
                chosen = group.latest
            } else {
                chosen = group.versions.first { $0.id == requested } ?? group.latest
            }
            guard let chosen, let data = FileManager.default.contents(atPath: chosen.path) else { return nil }
            return (group, chosen, data)
        }.value
        guard case let (group, listing, data)? = found else {
            return .failure(version.map { "The image \(requested) has no version \($0) on this Mac. list_images names its versions." }
                ?? GeneratedImageStore.RevisionFailure.unknownImage(requested).localizedDescription)
        }
        return MediaToolResult(
            text: Self.imageDescription(group: group, shown: listing),
            images: [MCPToolImage(data: data, mimeType: GeneratedImageStore.mediaType(of: data) ?? "image/png")],
            isError: false
        )
    }

    // MARK: generate_image

    func generateImage(arguments: [String: Any]) async -> MediaToolResult {
        guard let prompt = Self.trimmedOrNil(arguments["prompt"] as? String) else {
            return .failure("generate_image needs a prompt describing the picture.")
        }
        let shape = (arguments["shape"] as? String).flatMap { ImageGenerationCatalog.Shape(rawValue: $0.lowercased()) } ?? .square
        let quality = (arguments["quality"] as? String).flatMap { ImageGenerationCatalog.Quality(rawValue: $0.lowercased()) } ?? .medium
        let revising = ReviewSessionManager.imageID(fromArgument: arguments["revises"])
        let title = GeneratedImageStore.cleanTitle(arguments["title"] as? String)
        // Refused before anything is drawn, so a missing title costs nothing.
        guard title != nil || revising != nil else {
            return .failure("generate_image needs a title for a new image: two to six words naming it, as a file is named.")
        }
        let model = await MainActor.run { MacImageGenerationSettings.model }
        do {
            // The notebook it lives in, checked before anything is drawn.
            let notebook = try await notebookForMadeThing(notebookID: arguments["notebook_id"] as? String)
            let stored = try await ManagedImageGeneration.drawAndStore(
                prompt: prompt,
                title: title,
                model: model,
                shape: shape,
                quality: quality,
                revising: revising,
                usageTask: "mcp_image",
                notebookID: notebook?.id
            )
            return await storedResult(stored, verb: "Drew")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: save_image

    func saveImage(
        arguments: [String: Any],
        readLocalFile: @escaping @Sendable (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0), options: [.mappedIfSafe]) }
    ) async -> MediaToolResult {
        guard let prompt = Self.trimmedOrNil(arguments["prompt"] as? String) else {
            return .failure("save_image needs the prompt the picture was made from: a picture is never kept without one. For a picture made without a prompt, pass a sentence saying what it shows.")
        }
        let base64 = Self.trimmedOrNil(arguments["image_base64"] as? String)
        let localPath = Self.trimmedOrNil(arguments["local_path"] as? String)
        guard (base64 == nil) != (localPath == nil) else {
            return .failure("save_image needs exactly one of image_base64 and local_path.")
        }
        let data: Data
        if let base64 {
            let payload = base64.range(of: ";base64,").map { String(base64[$0.upperBound...]) } ?? base64
            guard let decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
                return .failure("image_base64 is not base64.")
            }
            data = decoded
        } else {
            let path = (localPath! as NSString).expandingTildeInPath
            do {
                data = try await Task.detached(priority: .userInitiated) { try readLocalFile(path) }.value
            } catch {
                return .failure("Could not read \(path): \(error.localizedDescription)")
            }
        }
        guard !data.isEmpty, data.count <= Self.maxSavedImageBytes else {
            return .failure(data.isEmpty ? "The picture is empty." : "The picture is \(data.count / 1_048_576) MB; save_image takes at most 20 MB.")
        }
        guard let mediaType = GeneratedImageStore.mediaType(of: data) else {
            return .failure("That is not an image this Mac can read. Pass a PNG, JPEG, WebP, HEIC or another common image format.")
        }
        let model = Self.trimmedOrNil(arguments["model"] as? String)
        let revising = ReviewSessionManager.imageID(fromArgument: arguments["revises"])
        let title = GeneratedImageStore.cleanTitle(arguments["title"] as? String)
        guard title != nil || revising != nil else {
            return .failure("save_image needs a title for a new image: two to six words naming it, as a file is named.")
        }
        do {
            let notebookID = try await notebookForMadeThing(notebookID: arguments["notebook_id"] as? String)?.id
            let stored = try await Task.detached(priority: .userInitiated) {
                try GeneratedImageStore.store(
                    GeneratedImage(data: data, mediaType: mediaType),
                    origin: .saved,
                    text: prompt,
                    title: title,
                    model: model,
                    revising: revising,
                    notebookID: notebookID
                )
            }.value
            return await storedResult(stored, verb: "Saved", includeImage: false)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: rename_image

    func renameImage(arguments: [String: Any]) async -> MediaToolResult {
        guard let requested = ReviewSessionManager.imageID(fromArgument: arguments["image"]) else {
            return .failure("rename_image needs an image: its image_id from list_images.")
        }
        guard let title = GeneratedImageStore.cleanTitle(arguments["title"] as? String) else {
            return .failure("rename_image needs a title: a few words naming the picture.")
        }
        do {
            let text = try await Task.detached(priority: .userInitiated) { () throws -> String in
                guard let group = GeneratedImageStore.group(containing: requested) else {
                    throw GeneratedImageStore.RevisionFailure.unknownImage(requested)
                }
                try GeneratedImageStore.rename(group: group, to: title)
                return "Image \(group.imageID) is now titled \"\(title)\"."
            }.value
            return MediaToolResult(text: text, images: [], isError: false)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: delete_image

    func deleteImage(arguments: [String: Any]) async -> MediaToolResult {
        guard let requested = ReviewSessionManager.imageID(fromArgument: arguments["image"]) else {
            return .failure("delete_image needs an image: its image_id from list_images.")
        }
        let version = Self.intArgument(arguments["version"])
        do {
            let text = try await Task.detached(priority: .userInitiated) { () throws -> String in
                guard let group = GeneratedImageStore.group(containing: requested) else {
                    throw GeneratedImageStore.RevisionFailure.unknownImage(requested)
                }
                if let version {
                    guard let listing = group.versions.first(where: { $0.version == version }) else {
                        throw MCPError.invalidInput("The image \(group.imageID) has no version \(version). list_images names its versions.")
                    }
                    try GeneratedImageStore.trash(id: listing.id)
                    let left = group.versions.count - 1
                    return "Moved version \(version) of image \(group.imageID) to the Trash; \(left == 0 ? "no versions are left." : "\(left) version\(left == 1 ? "" : "s") remain.")"
                }
                try GeneratedImageStore.trash(group: group)
                return "Moved image \(group.imageID) and its \(group.versions.count) version\(group.versions.count == 1 ? "" : "s") to the Trash."
            }.value
            return MediaToolResult(text: text, images: [], isError: false)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Shared

    private func storedResult(_ stored: GeneratedImageStore.Listing, verb: String, includeImage: Bool = true) async -> MediaToolResult {
        let group = await Task.detached(priority: .userInitiated) {
            GeneratedImageStore.group(containing: stored.id)
        }.value
        var text = group.map { Self.imageDescription(group: $0, shown: stored) } ?? "image_id \(stored.imageID)"
        text = (stored.version > 1
            ? "\(verb) version \(stored.version) of image \(stored.imageID); it is shown in place of the earlier ones, which are kept.\n\n"
            : "\(verb) a new image.\n\n") + text
        var images: [MCPToolImage] = []
        if includeImage, let data = FileManager.default.contents(atPath: stored.path) {
            images.append(MCPToolImage(data: data, mimeType: GeneratedImageStore.mediaType(of: data) ?? "image/png"))
        }
        return MediaToolResult(text: text, images: images, isError: false)
    }

    /// One image as text: ids, the shown version's prompt and file, and every
    /// version.
    static func imageDescription(group: GeneratedImageStore.ImageGroup, shown: GeneratedImageStore.Listing) -> String {
        var lines = ["image_id: \(group.imageID)"]
        lines.append("Title: \(group.title ?? "(none; stored before titles were kept — rename_image gives it one)")")
        lines.append("Showing: version \(shown.version) of \(group.versions.count) (id \(shown.id))")
        if let model = shown.details?.model { lines.append("Model: \(model)") }
        if shown.details?.origin == .saved { lines.append("Made elsewhere and saved with save_image") }
        lines.append("Made: \(shown.createdAt.formatted(date: .abbreviated, time: .shortened))")
        if let notebookID = group.notebookID { lines.append("Notebook: \(notebookID)") }
        lines.append("Prompt: \(shown.details?.text.isEmpty == false ? shown.details!.text : "(not recorded; stored before prompts were kept)")")
        lines.append("File: \(shown.path)")
        if let reference = shown.reference {
            lines.append("In a ForeverLM chat or Doc: \(reference.markdown(alt: GeneratedImageStore.altText(for: group)))")
        }
        if group.versions.count > 1 {
            lines.append("Versions, newest first:")
            for version in group.versions {
                lines.append("- v\(version.version) \(version.id) · \(GeneratedImageStore.altText(version.details?.text ?? ""))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A JSON number or numeric string as an Int.
    static func intArgument(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber, !(raw is Bool) { return number.intValue }
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
