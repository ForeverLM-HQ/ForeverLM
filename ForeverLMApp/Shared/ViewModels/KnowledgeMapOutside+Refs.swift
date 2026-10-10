import Foundation

// The refs of the three kinds the parity build added (`canvas`, `chat`,
// `picture`), named in one place.
extension KnowledgeMapOutside {
    static func chatRef(_ sessionID: String) -> String {
        KnowledgeMap.ItemRef(kind: .chat, id: sessionID).description
    }

    static func canvasRef(_ canvasID: String) -> String {
        KnowledgeMap.ItemRef(kind: .canvas, id: canvasID).description
    }

    static func pictureRef(_ imageID: String) -> String {
        KnowledgeMap.ItemRef(kind: .picture, id: imageID).description
    }
}
