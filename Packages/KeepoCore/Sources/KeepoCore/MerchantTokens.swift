import Foundation

/// The vocabulary `MerchantNormalizer` strips, kept as data so it can be
/// read, reviewed and tested on its own.
///
/// **Scope is the countries behind the 31 currencies `currencies` ships
/// with**, not the world — a card descriptor Keepo can never see is a
/// collision risk with no upside. Everything here is written uppercased,
/// because the normalizer uppercases before it matches, and escaped as a
/// literal before it reaches a pattern.
///
/// **Two-letter suffixes are the risk class.** A US card descriptor
/// routinely ends in a two-letter state code, so `AB` (Sweden), `AG`
/// (Switzerland), `AS` (Norway), `NV`, `KG`, `OY`, `SA`, `SL` and `ME` are
/// deliberately absent — `ME` is both a Brazilian company form and the code
/// for Maine. They are admitted only in punctuated form (`A.S.`, `B.V.`,
/// `S.A.`, `A/S`), which no state code can imitate. **`CO` is the one
/// deliberate exception**, kept at the user's instruction with its cost
/// accepted: `LUCKY CO` normalizes to `LUCKY` and collides with a shop
/// genuinely called `LUCKY`. Bare `SPA` is excluded for the same reason
/// pointing the other way — a nail salon is not an Italian S.p.A.
enum MerchantTokens {
    /// Payment aggregators that put their own tag in front of the shop's
    /// name. **The `*` is what makes these safe to strip**: `SQ`, `PP`, `SP`
    /// and `IZ` are two letters, and only the star that always follows them
    /// separates an aggregator tag from the first word of a name.
    static let aggregators = [
        // North America
        "SQ", "TST", "TOAST", "PAYPAL", "PP", "SP", "STRIPE",
        // Europe — SumUp and Zettle are this continent's Square
        "SUMUP", "ZETTLE", "IZ", "ADYEN", "MOLLIE", "VIVA", "REDSYS", "WORLDLINE", "NAYAX"
    ]

    /// Company forms that **lead** the name rather than trail it. A category
    /// the normalizer did not have before: in Indonesia `PT` and `CV` come
    /// first, so stripping suffixes alone leaves two keys for one shop.
    /// Matched only with whitespace behind them, so `PTY LTD` is untouched.
    static let companyPrefixes = ["PT", "CV"]

    /// Company forms written in CJK, which sit on **either** side of the
    /// name and take no separator at all — `株式会社ローソン` and
    /// `ローソン株式会社` are the same shop. Zero collision risk: these are
    /// whole corporate morphemes, not initials.
    static let ideographicCompanyForms = [
        // Japan
        "株式会社", "有限会社", "合同会社", "㈱", "(株)",
        // Korea
        "주식회사", "㈜", "(주)",
        // China, Hong Kong
        "股份有限公司", "有限責任公司", "有限责任公司", "有限公司",
        // Thailand
        "บริษัท", "จำกัด"
    ]

    /// Company forms that trail the name. Matched behind a `[\s,]+`
    /// boundary — which is the fix itself: `,LLC` is as common in real
    /// Square output as ` LLC`, and a literal leading space could never
    /// match it.
    static let corporateSuffixes = [
        // Anglophone — US, CA, GB, IE, AU, NZ, IN, SG, MY, HK, PH, ZA, IL
        "LLC", "L.L.C.", "LLP", "L.L.P.", "PLLC", "L.P.",
        "INC", "INC.", "INCORPORATED", "CORP", "CORP.", "CORPORATION",
        "LTD", "LTD.", "LIMITED", "CO", "CO.", "CO., LTD.", "CO. LTD.",
        "PLC", "P.L.C.", "CIC", "ULC", "LTEE", "LTÉE",
        "PTY LTD", "PTY LTD.", "PTY. LTD.", "(PTY) LTD", "(PTY) LTD.", "PTY",
        "PVT LTD", "PVT LTD.", "PVT. LTD.", "PRIVATE LIMITED",
        "PTE LTD", "PTE LTD.", "PTE. LTD.", "PTE",
        "SDN BHD", "SDN. BHD.", "BHD", "BERHAD",
        "NPC", "OPC", "PCL", "PUBLIC COMPANY LIMITED", "K.K.",
        // German-speaking — DE, AT, CH
        "GMBH", "GMBH & CO. KG", "GMBH & CO KG", "OHG", "GBR", "E.K.", "E.V.",
        // French-speaking — FR, BE, LU, CH
        "SARL", "S.A.R.L.", "SAS", "S.A.S.", "SASU", "EURL", "SNC", "SCI", "SPRL", "BVBA", "ASBL",
        // Iberia and Latin America — ES, PT, MX, BR
        "S.L.", "S.L.U.", "S.A.", "S.A.U.", "S.C.", "S.COOP.", "C.B.",
        "LDA", "LDA.", "UNIPESSOAL LDA",
        "S.A. DE C.V.", "SA DE CV", "S. DE R.L. DE C.V.", "S. DE R.L.", "S.A.P.I. DE C.V.",
        "LTDA", "LTDA.", "EIRELI", "EPP",
        // Italy and Greece
        "S.R.L.", "SRL", "S.P.A.", "S.N.C.", "SOC. COOP.", "A.E.", "E.P.E.", "O.E.", "I.K.E.",
        // Benelux
        "B.V.", "N.V.", "V.O.F.", "C.V.",
        // Nordics and Iceland — SE, NO, DK, FI, IS
        "AKTIEBOLAG", "A/S", "ASA", "ANS", "NUF", "APS", "I/S", "K/S", "P/S", "OYJ", "EHF", "EHF.", "HF.",
        // Central and Eastern Europe — PL, CZ, SK, HU, RO, BG
        "SP. Z O.O.", "SP Z O.O.", "SP. Z.O.O.", "SPÓŁKA Z O.O.", "SP.J.", "SP. J.", "SP. K.",
        "S.R.O.", "SRO", "SPOL. S R.O.", "A.S.", "V.O.S.", "Z.S.", "K.S.",
        "KFT", "KFT.", "ZRT", "ZRT.", "NYRT", "NYRT.", "BT.", "KKT.",
        "PFA", "OOD", "EOOD", "EAD",
        // Türkiye
        "A.Ş.", "LTD. ŞTI.", "LTD ŞTI.", "ŞTI.", "STI.",
        // Indonesia
        "TBK", "PERSERO"
    ]
}
