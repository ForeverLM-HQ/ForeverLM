// Where a finished manual dictation goes: the draft or straight to send.
import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

enum ManualDictationResultDestination {
    case draft
    case send
}
