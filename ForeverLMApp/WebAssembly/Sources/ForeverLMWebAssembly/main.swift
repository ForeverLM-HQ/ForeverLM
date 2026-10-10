import ForeverLMCore
import JavaScriptKit

private let protocolVersion = 4
private var retainedClosures: [JSClosure] = []

private func stringArgument(_ arguments: [JSValue], at index: Int = 0) -> String? {
    guard arguments.indices.contains(index) else { return nil }
    return arguments[index].string
}

private func optionalString(_ value: String?) -> JSValue {
    value.map(JSValue.string) ?? .null
}

let api = JSObject.global.Object.function!.new()
api.protocolVersion = .number(Double(protocolVersion))
api.tutorContractVersion = .number(Double(TutorContract.protocolVersion))
api.tutorCoreInstructions = .string(TutorContract.coreInstructions)
api.tutorReviewPreparationInstructions = .string(TutorContract.reviewPreparationInstructions)
api.tutorToolsJSON = optionalString(TutorContract.encodedTools(
    includeWholeSourceReviewQueue: true,
    endSessionSupportsGaps: true
))
api.aiTaskSettingsCatalogVersion = .number(Double(AITaskSettingsCatalog.version))
api.aiTaskSettingsJSON = optionalString(AITaskSettingsCatalog.encodedTasks())

let encodeArticleReadingPosition = JSClosure { arguments in
    guard let fraction = arguments.first?.number,
          fraction.isFinite
    else { return .null }
    return optionalString(ArticleReadingPositionLocator(scrollFraction: fraction).encoded)
}
api.encodeArticleReadingPosition = .object(encodeArticleReadingPosition)
retainedClosures.append(encodeArticleReadingPosition)

let decodeArticleReadingPosition = JSClosure { arguments in
    guard let encoded = stringArgument(arguments),
          let fraction = ArticleReadingPositionLocator(encoded: encoded)?.webScrollFraction
    else { return .null }
    return .number(fraction)
}
api.decodeArticleReadingPosition = .object(decodeArticleReadingPosition)
retainedClosures.append(decodeArticleReadingPosition)

let canonicalSourceType = JSClosure { arguments in
    let sourceType = stringArgument(arguments) ?? "article"
    return .string(ForeverLMCore.canonicalSourceType(sourceType))
}
api.canonicalSourceType = .object(canonicalSourceType)
retainedClosures.append(canonicalSourceType)

let youtubeVideoID = JSClosure { arguments in
    optionalString(stringArgument(arguments).flatMap(ForeverLMCore.youtubeVideoID(from:)))
}
api.youtubeVideoID = .object(youtubeVideoID)
retainedClosures.append(youtubeVideoID)

let youtubeThumbnailURL = JSClosure { arguments in
    optionalString(stringArgument(arguments).flatMap(ForeverLMCore.youtubeThumbnailURL(for:)))
}
api.youtubeThumbnailURL = .object(youtubeThumbnailURL)
retainedClosures.append(youtubeThumbnailURL)

let youtubeEmbedURL = JSClosure { arguments in
    optionalString(stringArgument(arguments).flatMap(ForeverLMCore.youtubeEmbedURL(for:)))
}
api.youtubeEmbedURL = .object(youtubeEmbedURL)
retainedClosures.append(youtubeEmbedURL)

let sourceTabID = JSClosure { arguments in
    let sourceType = stringArgument(arguments) ?? "article"
    let discoveryOrigin = stringArgument(arguments, at: 1)
    let url = stringArgument(arguments, at: 2)
    return .string(ForeverLMCore.sourceTabID(
        sourceType: sourceType,
        discoveryOrigin: discoveryOrigin,
        url: url
    ))
}
api.sourceTabID = .object(sourceTabID)
retainedClosures.append(sourceTabID)

let supportsReadTracking = JSClosure { arguments in
    let sourceType = stringArgument(arguments) ?? "article"
    let url = stringArgument(arguments, at: 1)
    let hasLocalFile = arguments.indices.contains(2) ? arguments[2].boolean == true : false
    let isArchivedArticle = arguments.indices.contains(3) ? arguments[3].boolean == true : false
    let isPDF = arguments.indices.contains(4) ? arguments[4].boolean == true : false
    return .boolean(ForeverLMCore.supportsReadTracking(
        sourceType: sourceType,
        url: url,
        hasLocalFile: hasLocalFile,
        isArchivedArticle: isArchivedArticle,
        isPDF: isPDF
    ))
}
api.supportsReadTracking = .object(supportsReadTracking)
retainedClosures.append(supportsReadTracking)

let wholeSourceReviewDueAt = JSClosure { arguments in
    guard let lastReviewedAt = arguments.first?.number,
          lastReviewedAt.isFinite,
          arguments.indices.contains(1),
          let reviewCountNumber = arguments[1].number,
          reviewCountNumber.isFinite
    else { return .null }
    let lastScore = arguments.indices.contains(2) ? arguments[2].number : nil
    guard lastScore?.isFinite != false,
          let result = ForeverLMCore.wholeSourceReviewDueAtMilliseconds(
              lastReviewedAtMilliseconds: lastReviewedAt,
              reviewCount: Int(max(0, min(reviewCountNumber, 100_000))),
              lastScore: lastScore
          )
    else { return .null }
    return .number(result)
}
api.wholeSourceReviewDueAt = .object(wholeSourceReviewDueAt)
retainedClosures.append(wholeSourceReviewDueAt)

let wholeSourceFirstReviewDueAt = JSClosure { arguments in
    guard let consumedAt = arguments.first?.number,
          let result = ForeverLMCore.wholeSourceFirstReviewDueAtMilliseconds(
              consumedAtMilliseconds: consumedAt
          )
    else { return .null }
    return .number(result)
}
api.wholeSourceFirstReviewDueAt = .object(wholeSourceFirstReviewDueAt)
retainedClosures.append(wholeSourceFirstReviewDueAt)

// A card's schedule from Sitting answers with the learner's offsets (docs/cloudkit-schema-design.md
// §8c): JSON in and out, pinned by schema/vectors/card-schedule.json.
let cardScheduleFold = JSClosure { arguments in
    optionalString(stringArgument(arguments).flatMap(ForeverLMCore.cardScheduleFold(json:)))
}
api.cardScheduleFold = .object(cardScheduleFold)
retainedClosures.append(cardScheduleFold)

JSObject.global.foreverLMCore = .object(api)
