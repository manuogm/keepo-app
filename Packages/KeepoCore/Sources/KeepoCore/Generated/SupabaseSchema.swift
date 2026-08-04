import Foundation
import Supabase

public enum GraphqlPublicSchema {
}
public enum PublicSchema {
  public enum AccountKind: String, Codable, Hashable, Sendable {
    case ledger = "ledger"
    case valuation = "valuation"
  }
  public enum AccountSubtype: String, Codable, Hashable, Sendable {
    case checking = "checking"
    case cash = "cash"
    case creditCard = "credit_card"
    case loan = "loan"
    case investment = "investment"
  }
  public struct AccountsSelect: Codable, Hashable, Sendable {
    public let archivedAt: String?
    public let countsTowardFi: Bool
    public let createdAt: String
    public let createdBy: UUID
    public let currency: String
    public let deletedAt: String?
    public let id: UUID
    public let includeInTotal: Bool
    public let kind: AccountKind
    public let name: String
    public let openingBalance: Decimal
    public let openingBalanceAt: String
    public let ownerId: UUID
    public let subtype: AccountSubtype
    public let updatedAt: String
    public let version: Int32
    public enum CodingKeys: String, CodingKey {
      case archivedAt = "archived_at"
      case countsTowardFi = "counts_toward_fi"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case id = "id"
      case includeInTotal = "include_in_total"
      case kind = "kind"
      case name = "name"
      case openingBalance = "opening_balance"
      case openingBalanceAt = "opening_balance_at"
      case ownerId = "owner_id"
      case subtype = "subtype"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct AccountsInsert: Codable, Hashable, Sendable {
    public let archivedAt: String?
    public let countsTowardFi: Bool?
    public let createdAt: String?
    public let createdBy: UUID
    public let currency: String
    public let deletedAt: String?
    public let id: UUID?
    public let includeInTotal: Bool?
    public let kind: AccountKind
    public let name: String
    public let openingBalance: Decimal?
    public let openingBalanceAt: String?
    public let ownerId: UUID
    public let subtype: AccountSubtype
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case archivedAt = "archived_at"
      case countsTowardFi = "counts_toward_fi"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case id = "id"
      case includeInTotal = "include_in_total"
      case kind = "kind"
      case name = "name"
      case openingBalance = "opening_balance"
      case openingBalanceAt = "opening_balance_at"
      case ownerId = "owner_id"
      case subtype = "subtype"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct AccountsUpdate: Codable, Hashable, Sendable {
    public let archivedAt: String?
    public let countsTowardFi: Bool?
    public let createdAt: String?
    public let createdBy: UUID?
    public let currency: String?
    public let deletedAt: String?
    public let id: UUID?
    public let includeInTotal: Bool?
    public let kind: AccountKind?
    public let name: String?
    public let openingBalance: Decimal?
    public let openingBalanceAt: String?
    public let ownerId: UUID?
    public let subtype: AccountSubtype?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case archivedAt = "archived_at"
      case countsTowardFi = "counts_toward_fi"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case id = "id"
      case includeInTotal = "include_in_total"
      case kind = "kind"
      case name = "name"
      case openingBalance = "opening_balance"
      case openingBalanceAt = "opening_balance_at"
      case ownerId = "owner_id"
      case subtype = "subtype"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct BalanceSnapshotsSelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let asOf: String
    public let createdAt: String
    public let createdBy: UUID
    public let currency: String
    public let id: UUID
    public let value: Decimal
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case id = "id"
      case value = "value"
    }
  }
  public struct BalanceSnapshotsInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let asOf: String
    public let createdAt: String?
    public let createdBy: UUID
    public let currency: String
    public let id: UUID?
    public let value: Decimal
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case id = "id"
      case value = "value"
    }
  }
  public struct BalanceSnapshotsUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let asOf: String?
    public let createdAt: String?
    public let createdBy: UUID?
    public let currency: String?
    public let id: UUID?
    public let value: Decimal?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case id = "id"
      case value = "value"
    }
  }
  public struct CurrenciesSelect: Codable, Hashable, Sendable {
    public let code: String
    public let minorUnit: Int16
    public enum CodingKeys: String, CodingKey {
      case code = "code"
      case minorUnit = "minor_unit"
    }
  }
  public struct CurrenciesInsert: Codable, Hashable, Sendable {
    public let code: String
    public let minorUnit: Int16
    public enum CodingKeys: String, CodingKey {
      case code = "code"
      case minorUnit = "minor_unit"
    }
  }
  public struct CurrenciesUpdate: Codable, Hashable, Sendable {
    public let code: String?
    public let minorUnit: Int16?
    public enum CodingKeys: String, CodingKey {
      case code = "code"
      case minorUnit = "minor_unit"
    }
  }
  public struct ProfilesSelect: Codable, Hashable, Sendable {
    public let baseCurrency: String?
    public let createdAt: String
    public let id: UUID
    public let onboardedAt: String?
    public let updatedAt: String
    public enum CodingKeys: String, CodingKey {
      case baseCurrency = "base_currency"
      case createdAt = "created_at"
      case id = "id"
      case onboardedAt = "onboarded_at"
      case updatedAt = "updated_at"
    }
  }
  public struct ProfilesInsert: Codable, Hashable, Sendable {
    public let baseCurrency: String?
    public let createdAt: String?
    public let id: UUID
    public let onboardedAt: String?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case baseCurrency = "base_currency"
      case createdAt = "created_at"
      case id = "id"
      case onboardedAt = "onboarded_at"
      case updatedAt = "updated_at"
    }
  }
  public struct ProfilesUpdate: Codable, Hashable, Sendable {
    public let baseCurrency: String?
    public let createdAt: String?
    public let id: UUID?
    public let onboardedAt: String?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case baseCurrency = "base_currency"
      case createdAt = "created_at"
      case id = "id"
      case onboardedAt = "onboarded_at"
      case updatedAt = "updated_at"
    }
  }
  public struct AccountBalancesSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let balance: Decimal?
    public let currency: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case balance = "balance"
      case currency = "currency"
    }
  }
  public struct AccountsWithBalancesSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let archivedAt: String?
    public let balance: Decimal?
    public let countsTowardFi: Bool?
    public let currency: String?
    public let includeInTotal: Bool?
    public let kind: AccountKind?
    public let minorUnit: Int16?
    public let name: String?
    public let subtype: AccountSubtype?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case archivedAt = "archived_at"
      case balance = "balance"
      case countsTowardFi = "counts_toward_fi"
      case currency = "currency"
      case includeInTotal = "include_in_total"
      case kind = "kind"
      case minorUnit = "minor_unit"
      case name = "name"
      case subtype = "subtype"
    }
  }
}
