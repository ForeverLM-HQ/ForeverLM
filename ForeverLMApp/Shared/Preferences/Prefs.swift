import Foundation

/// Every preference ForeverLM stores, declared once.
///
/// A key is declared in the namespace of its feature (`Prefs+<Area>.swift`),
/// with its stored name, value type, default, and whether it follows the
/// account (`AccountKey`) or stays on the device (`DeviceKey`, with the
/// reason). Keys built at runtime from a prefix and an id are families
/// (`Prefs+Families.swift`). `PreferenceRegistry` gathers them, and
/// `SyncedPreferenceKeys` is derived from the registry, so the sync boundary
/// is these declarations.
///
/// Rules for a declaration:
/// - The name is the stored string and never changes once a build has shipped
///   it. Other devices, the web and the hosted MCP name the same row, and
///   `UnitTests/Fixtures/preference-keys.golden.json` holds every name and
///   scope so a change is deliberate.
/// - A new key is added to its namespace's `all` and to the golden file.
/// - A key has a default only where every reader agreed on one. Elsewhere it
///   is optional: absent reads as nil, and the reader says what absent means,
///   as it did before (`?? defaultVoice`). The types here are the ones both
///   platforms compile, so an enum the Mac alone defines is declared by its
///   raw type and mapped where it is read.
/// - Files under `Shared/Portable` cannot depend on this directory (they also
///   build into the WebAssembly core), so their key constants stay their own
///   and a test holds the two spellings together.
enum Prefs {}
