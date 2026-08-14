import Foundation

/// Lets any `Binding<UUID?>` drive `.sheet(item:)` directly, without a
/// per-screen `EditingXId` wrapper struct + `Binding` `.map` helper.
/// AccountsListView and CategoriesView each carried their own private copy
/// of that wrapper ("simpler than making UUID Identifiable app-wide for one
/// call site," per the original comment) — the conflict sheet's `conflictId`
/// state made that a third occurrence, the signal to extract this instead.
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
