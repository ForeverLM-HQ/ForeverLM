// The permit pool that bounds how many audio chunks generate at once.
#if os(macOS)
import AVFoundation
import CryptoKit
import Foundation
import MediaPlayer
import os
import PDFKit
import SwiftUI
import WebKit

/// Bounds how many chunks generate at once, and hands each freed permit to the
/// chunk playback will reach soonest.
///
/// Arrival order carries no information here: every chunk task for a generation
/// starts in the same turn, so a plain FIFO queue admits them in whatever order
/// the scheduler happened to wake them — and a retry sends a chunk to the back.
/// That left the generator working on chunk 40 while playback sat waiting on
/// chunk 3.
actor ArticleSpeechAudioCachePermitPool {
    private var available: Int
    private var waiters: [(order: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(limit: Int) {
        self.available = max(1, limit)
    }

    func acquire(order: Int) async {
        if available > 0 {
            available -= 1
            return
        }

        await withCheckedContinuation { continuation in
            let insertion = waiters.firstIndex { $0.order > order } ?? waiters.endIndex
            waiters.insert((order: order, continuation: continuation), at: insertion)
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
#endif
