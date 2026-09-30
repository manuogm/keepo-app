import Foundation

/// How a "tick as many as you like, or all of them" filter axis changes when
/// one option is tapped.
///
/// The three rules are the whole type, and each exists because the obvious
/// implementation gets it wrong:
///
///   1. **"All" is `nil`, never every id ticked.** A filter holding all
///      twenty-three category ids and one holding none are the same list on
///      screen, but only the second keeps saying "all categories" after the
///      user adds a twenty-fourth. Absence is the only representation of
///      "everything" that stays true.
///   2. **From "all", tapping an option means only that option.** The
///      alternative reading — twenty-three ticked, minus the one tapped — is
///      what a user asking for Groceries never means.
///   3. **Unticking the last option goes back to "all"**, not to the empty
///      set. Empty means "no categories", which `TransactionFilter` honours
///      literally with a list of nothing; a user clearing their last tick is
///      undoing the filter, not asking for a blank screen.
public enum FilterSelection {
    /// The axis after `value` is tapped. See the type's own rules.
    public static func toggling<ID: Hashable>(_ value: ID, in selection: Set<ID>?) -> Set<ID>? {
        guard var selection else { return [value] }
        if selection.contains(value) {
            selection.remove(value)
            return selection.isEmpty ? nil : selection
        }
        selection.insert(value)
        return selection
    }
}
