import Foundation
import GRDB
import KeepoCore

// What the Sync Conflict sheet needs of an account: the one row, and that row
// as a refused write would have left it. Split out of LocalAccountRow.swift,
// which is about the list.
extension LocalAccountRow {
    /// One account by id, exactly as the Accounts list draws it — its balance,
    /// its base-currency figure, its household marker.
    static func fetchOne(
        _ database: Database, id: String, ownerId: String, baseCurrency: String
    ) throws -> LocalAccountRow? {
        try fetchAll(database, ownerId: ownerId, baseCurrency: baseCurrency)
            .first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// This row as a refused write would have left it — the sheet's "your
    /// change" tile. `nil` leaves a field as it is. A new balance is converted
    /// to the base currency by the same `BaseConversion` the list uses, at
    /// today's rate, so the tile reads exactly as the list would draw it.
    func changing(
        name: String? = nil, icon: String? = nil, color: String? = nil, kind: PublicSchema.AccountKind? = nil,
        archived: Bool? = nil, balanceE4: Int64? = nil, in database: Database
    ) throws -> LocalAccountRow {
        var balanceBaseE4 = self.balanceBaseE4
        if let balanceE4, let base = baseCurrencyInfo?.code {
            let today = PostgresDate.dateOnlyString(Date(), calendar: utcCalendar)
            balanceBaseE4 = try BaseConversion(base, at: today)(database, balanceE4, from: currency)
        }
        let archivedAt: String? = archived.map {
            $0 ? self.archivedAt ?? PostgresDate.sqliteTimestampBoundaryString(Date()) : nil
        } ?? self.archivedAt
        return LocalAccountRow(
            id: id, ownerId: ownerId, name: name ?? self.name, currency: currency, currencyInfo: currencyInfo,
            kind: kind ?? self.kind, icon: icon ?? self.icon, color: color ?? self.color, archivedAt: archivedAt,
            sortOrder: sortOrder, version: version, isShared: isShared, sharedFrom: sharedFrom,
            openingBalanceAt: openingBalanceAt, hasMappedCard: hasMappedCard,
            balanceE4: balanceE4 ?? self.balanceE4, balanceBaseE4: balanceBaseE4, baseCurrencyInfo: baseCurrencyInfo
        )
    }
}
