import SwiftUI

// The shorter initialisers, for the screens that leave a slot empty — so
// Accounts, Dashboard and Categories don't name a generic parameter they
// never use.

extension ScopeBannerView where Accessory == EmptyView, Filters == EmptyView {
    init(
        title: String, session: SessionStore, showsPrivacyToggle: Bool = true,
        onOpenProfile: @escaping () -> Void
    ) {
        self.init(
            title: title, session: session, showsPrivacyToggle: showsPrivacyToggle,
            onOpenProfile: onOpenProfile, accessory: { EmptyView() }, filters: { EmptyView() }
        )
    }
}

extension ScopeBannerView where Filters == EmptyView {
    init(
        title: String,
        session: SessionStore,
        showsPrivacyToggle: Bool = true,
        showsPrivacyLesson: Bool = false,
        onOpenProfile: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.init(
            title: title, session: session, showsPrivacyToggle: showsPrivacyToggle,
            showsPrivacyLesson: showsPrivacyLesson,
            onOpenProfile: onOpenProfile, accessory: accessory, filters: { EmptyView() }
        )
    }
}
