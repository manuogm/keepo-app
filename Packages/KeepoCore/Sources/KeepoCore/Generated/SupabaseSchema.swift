import Foundation
import Supabase

public enum GraphqlPublicSchema {
}
public enum PublicSchema {
  public enum AccountKind: String, Codable, Hashable, Sendable {
    case ledger = "ledger"
    case valuation = "valuation"
  }
  public enum AccountScope: String, Codable, Hashable, Sendable {
    case me = "me"
    case household = "household"
    case total = "total"
  }
  public enum AccountSubtype: String, Codable, Hashable, Sendable {
    case checking = "checking"
    case cash = "cash"
    case creditCard = "credit_card"
    case loan = "loan"
    case investment = "investment"
  }
  public enum CategoryKind: String, Codable, Hashable, Sendable {
    case expense = "expense"
    case income = "income"
  }
  public enum FxSource: String, Codable, Hashable, Sendable {
    case ecb = "ecb"
  }
  public enum HouseholdInviteStatus: String, Codable, Hashable, Sendable {
    case pending = "pending"
    case accepted = "accepted"
    case revoked = "revoked"
    case expired = "expired"
  }
  public enum OpsEventLevel: String, Codable, Hashable, Sendable {
    case info = "info"
    case warning = "warning"
    case error = "error"
  }
  public enum RecurringFrequency: String, Codable, Hashable, Sendable {
    case weekly = "weekly"
    case monthly = "monthly"
    case yearly = "yearly"
  }
  public enum TransactionSource: String, Codable, Hashable, Sendable {
    case manual = "manual"
    case capture = "capture"
    case recurring = "recurring"
    case adjustment = "adjustment"
    case csvImport = "csv_import"
  }
  public enum TransactionStatus: String, Codable, Hashable, Sendable {
    case pending = "pending"
    case confirmed = "confirmed"
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
  public struct BudgetsSelect: Codable, Hashable, Sendable {
    public let amount: Decimal
    public let categoryId: UUID?
    public let createdAt: String
    public let currency: String
    public let id: UUID
    public let ownerId: UUID
    public let periodMonth: String
    public let updatedAt: String
    public let version: Int32
    public enum CodingKeys: String, CodingKey {
      case amount = "amount"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case currency = "currency"
      case id = "id"
      case ownerId = "owner_id"
      case periodMonth = "period_month"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct BudgetsInsert: Codable, Hashable, Sendable {
    public let amount: Decimal
    public let categoryId: UUID?
    public let createdAt: String?
    public let currency: String
    public let id: UUID?
    public let ownerId: UUID
    public let periodMonth: String
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case amount = "amount"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case currency = "currency"
      case id = "id"
      case ownerId = "owner_id"
      case periodMonth = "period_month"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct BudgetsUpdate: Codable, Hashable, Sendable {
    public let amount: Decimal?
    public let categoryId: UUID?
    public let createdAt: String?
    public let currency: String?
    public let id: UUID?
    public let ownerId: UUID?
    public let periodMonth: String?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case amount = "amount"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case currency = "currency"
      case id = "id"
      case ownerId = "owner_id"
      case periodMonth = "period_month"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct CardMappingsSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let cardIdentifier: String
    public let createdAt: String
    public let id: UUID
    public let ownerId: UUID
    public let updatedAt: String
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case cardIdentifier = "card_identifier"
      case createdAt = "created_at"
      case id = "id"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
    }
  }
  public struct CardMappingsInsert: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let cardIdentifier: String
    public let createdAt: String?
    public let id: UUID?
    public let ownerId: UUID
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case cardIdentifier = "card_identifier"
      case createdAt = "created_at"
      case id = "id"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
    }
  }
  public struct CardMappingsUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let cardIdentifier: String?
    public let createdAt: String?
    public let id: UUID?
    public let ownerId: UUID?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case cardIdentifier = "card_identifier"
      case createdAt = "created_at"
      case id = "id"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
    }
  }
  public struct CategoriesSelect: Codable, Hashable, Sendable {
    public let createdAt: String
    public let deletedAt: String?
    public let id: UUID
    public let isDefault: Bool
    public let kind: CategoryKind
    public let name: String
    public let ownerId: UUID
    public let systemKey: String?
    public let updatedAt: String
    public let version: Int32
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case isDefault = "is_default"
      case kind = "kind"
      case name = "name"
      case ownerId = "owner_id"
      case systemKey = "system_key"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct CategoriesInsert: Codable, Hashable, Sendable {
    public let createdAt: String?
    public let deletedAt: String?
    public let id: UUID?
    public let isDefault: Bool?
    public let kind: CategoryKind
    public let name: String
    public let ownerId: UUID
    public let systemKey: String?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case isDefault = "is_default"
      case kind = "kind"
      case name = "name"
      case ownerId = "owner_id"
      case systemKey = "system_key"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct CategoriesUpdate: Codable, Hashable, Sendable {
    public let createdAt: String?
    public let deletedAt: String?
    public let id: UUID?
    public let isDefault: Bool?
    public let kind: CategoryKind?
    public let name: String?
    public let ownerId: UUID?
    public let systemKey: String?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case isDefault = "is_default"
      case kind = "kind"
      case name = "name"
      case ownerId = "owner_id"
      case systemKey = "system_key"
      case updatedAt = "updated_at"
      case version = "version"
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
  public struct FiSettingsSelect: Codable, Hashable, Sendable {
    public let ownerId: UUID
    public let realReturnRate: Decimal
    public let targetAnnualSpend: Decimal?
    public let updatedAt: String
    public let withdrawalRate: Decimal
    public enum CodingKeys: String, CodingKey {
      case ownerId = "owner_id"
      case realReturnRate = "real_return_rate"
      case targetAnnualSpend = "target_annual_spend"
      case updatedAt = "updated_at"
      case withdrawalRate = "withdrawal_rate"
    }
  }
  public struct FiSettingsInsert: Codable, Hashable, Sendable {
    public let ownerId: UUID
    public let realReturnRate: Decimal?
    public let targetAnnualSpend: Decimal?
    public let updatedAt: String?
    public let withdrawalRate: Decimal?
    public enum CodingKeys: String, CodingKey {
      case ownerId = "owner_id"
      case realReturnRate = "real_return_rate"
      case targetAnnualSpend = "target_annual_spend"
      case updatedAt = "updated_at"
      case withdrawalRate = "withdrawal_rate"
    }
  }
  public struct FiSettingsUpdate: Codable, Hashable, Sendable {
    public let ownerId: UUID?
    public let realReturnRate: Decimal?
    public let targetAnnualSpend: Decimal?
    public let updatedAt: String?
    public let withdrawalRate: Decimal?
    public enum CodingKeys: String, CodingKey {
      case ownerId = "owner_id"
      case realReturnRate = "real_return_rate"
      case targetAnnualSpend = "target_annual_spend"
      case updatedAt = "updated_at"
      case withdrawalRate = "withdrawal_rate"
    }
  }
  public struct FxRatesSelect: Codable, Hashable, Sendable {
    public let currency: String
    public let fetchedAt: String
    public let rateDate: String
    public let rateToEur: Decimal
    public let source: FxSource
    public enum CodingKeys: String, CodingKey {
      case currency = "currency"
      case fetchedAt = "fetched_at"
      case rateDate = "rate_date"
      case rateToEur = "rate_to_eur"
      case source = "source"
    }
  }
  public struct FxRatesInsert: Codable, Hashable, Sendable {
    public let currency: String
    public let fetchedAt: String?
    public let rateDate: String
    public let rateToEur: Decimal
    public let source: FxSource
    public enum CodingKeys: String, CodingKey {
      case currency = "currency"
      case fetchedAt = "fetched_at"
      case rateDate = "rate_date"
      case rateToEur = "rate_to_eur"
      case source = "source"
    }
  }
  public struct FxRatesUpdate: Codable, Hashable, Sendable {
    public let currency: String?
    public let fetchedAt: String?
    public let rateDate: String?
    public let rateToEur: Decimal?
    public let source: FxSource?
    public enum CodingKeys: String, CodingKey {
      case currency = "currency"
      case fetchedAt = "fetched_at"
      case rateDate = "rate_date"
      case rateToEur = "rate_to_eur"
      case source = "source"
    }
  }
  public struct HouseholdAccountsSelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let householdId: UUID
    public let sharedAt: String
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case householdId = "household_id"
      case sharedAt = "shared_at"
    }
  }
  public struct HouseholdAccountsInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let householdId: UUID
    public let sharedAt: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case householdId = "household_id"
      case sharedAt = "shared_at"
    }
  }
  public struct HouseholdAccountsUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let householdId: UUID?
    public let sharedAt: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case householdId = "household_id"
      case sharedAt = "shared_at"
    }
  }
  public struct HouseholdInvitesSelect: Codable, Hashable, Sendable {
    public let createdAt: String
    public let expiresAt: String
    public let householdId: UUID
    public let id: UUID
    public let invitedBy: UUID
    public let status: HouseholdInviteStatus
    public let tokenHash: String
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case expiresAt = "expires_at"
      case householdId = "household_id"
      case id = "id"
      case invitedBy = "invited_by"
      case status = "status"
      case tokenHash = "token_hash"
    }
  }
  public struct HouseholdInvitesInsert: Codable, Hashable, Sendable {
    public let createdAt: String?
    public let expiresAt: String
    public let householdId: UUID
    public let id: UUID?
    public let invitedBy: UUID
    public let status: HouseholdInviteStatus?
    public let tokenHash: String
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case expiresAt = "expires_at"
      case householdId = "household_id"
      case id = "id"
      case invitedBy = "invited_by"
      case status = "status"
      case tokenHash = "token_hash"
    }
  }
  public struct HouseholdInvitesUpdate: Codable, Hashable, Sendable {
    public let createdAt: String?
    public let expiresAt: String?
    public let householdId: UUID?
    public let id: UUID?
    public let invitedBy: UUID?
    public let status: HouseholdInviteStatus?
    public let tokenHash: String?
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case expiresAt = "expires_at"
      case householdId = "household_id"
      case id = "id"
      case invitedBy = "invited_by"
      case status = "status"
      case tokenHash = "token_hash"
    }
  }
  public struct HouseholdMembersSelect: Codable, Hashable, Sendable {
    public let householdId: UUID
    public let joinedAt: String
    public let userId: UUID
    public enum CodingKeys: String, CodingKey {
      case householdId = "household_id"
      case joinedAt = "joined_at"
      case userId = "user_id"
    }
  }
  public struct HouseholdMembersInsert: Codable, Hashable, Sendable {
    public let householdId: UUID
    public let joinedAt: String?
    public let userId: UUID
    public enum CodingKeys: String, CodingKey {
      case householdId = "household_id"
      case joinedAt = "joined_at"
      case userId = "user_id"
    }
  }
  public struct HouseholdMembersUpdate: Codable, Hashable, Sendable {
    public let householdId: UUID?
    public let joinedAt: String?
    public let userId: UUID?
    public enum CodingKeys: String, CodingKey {
      case householdId = "household_id"
      case joinedAt = "joined_at"
      case userId = "user_id"
    }
  }
  public struct HouseholdsSelect: Codable, Hashable, Sendable {
    public let createdAt: String
    public let id: UUID
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case id = "id"
    }
  }
  public struct HouseholdsInsert: Codable, Hashable, Sendable {
    public let createdAt: String?
    public let id: UUID?
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case id = "id"
    }
  }
  public struct HouseholdsUpdate: Codable, Hashable, Sendable {
    public let createdAt: String?
    public let id: UUID?
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case id = "id"
    }
  }
  public struct MerchantCategoryMapSelect: Codable, Hashable, Sendable {
    public let categoryId: UUID
    public let merchantPattern: String
    public let ownerId: UUID
    public let updatedAt: String
    public enum CodingKeys: String, CodingKey {
      case categoryId = "category_id"
      case merchantPattern = "merchant_pattern"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
    }
  }
  public struct MerchantCategoryMapInsert: Codable, Hashable, Sendable {
    public let categoryId: UUID
    public let merchantPattern: String
    public let ownerId: UUID
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case categoryId = "category_id"
      case merchantPattern = "merchant_pattern"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
    }
  }
  public struct MerchantCategoryMapUpdate: Codable, Hashable, Sendable {
    public let categoryId: UUID?
    public let merchantPattern: String?
    public let ownerId: UUID?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case categoryId = "category_id"
      case merchantPattern = "merchant_pattern"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
    }
  }
  public struct NetWorthDailySelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let asOf: String
    public let balance: Decimal?
    public let currency: String
    public let ownerId: UUID
    public let updatedAt: String
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case balance = "balance"
      case currency = "currency"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
    }
  }
  public struct NetWorthDailyInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let asOf: String
    public let balance: Decimal?
    public let currency: String
    public let ownerId: UUID
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case balance = "balance"
      case currency = "currency"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
    }
  }
  public struct NetWorthDailyUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let asOf: String?
    public let balance: Decimal?
    public let currency: String?
    public let ownerId: UUID?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case balance = "balance"
      case currency = "currency"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
    }
  }
  public struct OpsEventsSelect: Codable, Hashable, Sendable {
    public let code: String
    public let detail: AnyJSON?
    public let id: UUID
    public let level: OpsEventLevel
    public let occurredAt: String
    public let source: String
    public enum CodingKeys: String, CodingKey {
      case code = "code"
      case detail = "detail"
      case id = "id"
      case level = "level"
      case occurredAt = "occurred_at"
      case source = "source"
    }
  }
  public struct OpsEventsInsert: Codable, Hashable, Sendable {
    public let code: String
    public let detail: AnyJSON?
    public let id: UUID?
    public let level: OpsEventLevel
    public let occurredAt: String?
    public let source: String
    public enum CodingKeys: String, CodingKey {
      case code = "code"
      case detail = "detail"
      case id = "id"
      case level = "level"
      case occurredAt = "occurred_at"
      case source = "source"
    }
  }
  public struct OpsEventsUpdate: Codable, Hashable, Sendable {
    public let code: String?
    public let detail: AnyJSON?
    public let id: UUID?
    public let level: OpsEventLevel?
    public let occurredAt: String?
    public let source: String?
    public enum CodingKeys: String, CodingKey {
      case code = "code"
      case detail = "detail"
      case id = "id"
      case level = "level"
      case occurredAt = "occurred_at"
      case source = "source"
    }
  }
  public struct OpsRateLimitsSelect: Codable, Hashable, Sendable {
    public let count: Int32
    public let functionName: String
    public let windowStartedAt: String
    public enum CodingKeys: String, CodingKey {
      case count = "count"
      case functionName = "function_name"
      case windowStartedAt = "window_started_at"
    }
  }
  public struct OpsRateLimitsInsert: Codable, Hashable, Sendable {
    public let count: Int32?
    public let functionName: String
    public let windowStartedAt: String?
    public enum CodingKeys: String, CodingKey {
      case count = "count"
      case functionName = "function_name"
      case windowStartedAt = "window_started_at"
    }
  }
  public struct OpsRateLimitsUpdate: Codable, Hashable, Sendable {
    public let count: Int32?
    public let functionName: String?
    public let windowStartedAt: String?
    public enum CodingKeys: String, CodingKey {
      case count = "count"
      case functionName = "function_name"
      case windowStartedAt = "window_started_at"
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
  public struct ReconciliationsSelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let adjustmentTxnId: UUID?
    public let asOf: String
    public let computedBalance: Decimal
    public let createdAt: String
    public let createdBy: UUID
    public let currency: String
    public let enteredBalance: Decimal
    public let id: UUID
    public let snapshotId: UUID?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case adjustmentTxnId = "adjustment_txn_id"
      case asOf = "as_of"
      case computedBalance = "computed_balance"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case enteredBalance = "entered_balance"
      case id = "id"
      case snapshotId = "snapshot_id"
    }
  }
  public struct ReconciliationsInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let adjustmentTxnId: UUID?
    public let asOf: String?
    public let computedBalance: Decimal
    public let createdAt: String?
    public let createdBy: UUID
    public let currency: String
    public let enteredBalance: Decimal
    public let id: UUID?
    public let snapshotId: UUID?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case adjustmentTxnId = "adjustment_txn_id"
      case asOf = "as_of"
      case computedBalance = "computed_balance"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case enteredBalance = "entered_balance"
      case id = "id"
      case snapshotId = "snapshot_id"
    }
  }
  public struct ReconciliationsUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let adjustmentTxnId: UUID?
    public let asOf: String?
    public let computedBalance: Decimal?
    public let createdAt: String?
    public let createdBy: UUID?
    public let currency: String?
    public let enteredBalance: Decimal?
    public let id: UUID?
    public let snapshotId: UUID?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case adjustmentTxnId = "adjustment_txn_id"
      case asOf = "as_of"
      case computedBalance = "computed_balance"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case enteredBalance = "entered_balance"
      case id = "id"
      case snapshotId = "snapshot_id"
    }
  }
  public struct RecurringRulesSelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let active: Bool
    public let amount: Decimal
    public let categoryId: UUID
    public let createdAt: String
    public let createdBy: UUID
    public let currency: String
    public let frequency: RecurringFrequency
    public let id: UUID
    public let lastMaterializedAt: String?
    public let nextDueAt: String
    public let ownerId: UUID
    public let updatedAt: String
    public let version: Int32
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case active = "active"
      case amount = "amount"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case frequency = "frequency"
      case id = "id"
      case lastMaterializedAt = "last_materialized_at"
      case nextDueAt = "next_due_at"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct RecurringRulesInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let active: Bool?
    public let amount: Decimal
    public let categoryId: UUID
    public let createdAt: String?
    public let createdBy: UUID
    public let currency: String
    public let frequency: RecurringFrequency
    public let id: UUID?
    public let lastMaterializedAt: String?
    public let nextDueAt: String
    public let ownerId: UUID
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case active = "active"
      case amount = "amount"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case frequency = "frequency"
      case id = "id"
      case lastMaterializedAt = "last_materialized_at"
      case nextDueAt = "next_due_at"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct RecurringRulesUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let active: Bool?
    public let amount: Decimal?
    public let categoryId: UUID?
    public let createdAt: String?
    public let createdBy: UUID?
    public let currency: String?
    public let frequency: RecurringFrequency?
    public let id: UUID?
    public let lastMaterializedAt: String?
    public let nextDueAt: String?
    public let ownerId: UUID?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case active = "active"
      case amount = "amount"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case frequency = "frequency"
      case id = "id"
      case lastMaterializedAt = "last_materialized_at"
      case nextDueAt = "next_due_at"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct SyncConflictsSelect: Codable, Hashable, Sendable {
    public let clientVersion: Int32
    public let createdAt: String
    public let id: UUID
    public let ownerId: UUID
    public let resolvedAt: String?
    public let rowId: UUID
    public let serverVersion: Int32
    public let tableName: String
    public enum CodingKeys: String, CodingKey {
      case clientVersion = "client_version"
      case createdAt = "created_at"
      case id = "id"
      case ownerId = "owner_id"
      case resolvedAt = "resolved_at"
      case rowId = "row_id"
      case serverVersion = "server_version"
      case tableName = "table_name"
    }
  }
  public struct SyncConflictsInsert: Codable, Hashable, Sendable {
    public let clientVersion: Int32
    public let createdAt: String?
    public let id: UUID?
    public let ownerId: UUID
    public let resolvedAt: String?
    public let rowId: UUID
    public let serverVersion: Int32
    public let tableName: String
    public enum CodingKeys: String, CodingKey {
      case clientVersion = "client_version"
      case createdAt = "created_at"
      case id = "id"
      case ownerId = "owner_id"
      case resolvedAt = "resolved_at"
      case rowId = "row_id"
      case serverVersion = "server_version"
      case tableName = "table_name"
    }
  }
  public struct SyncConflictsUpdate: Codable, Hashable, Sendable {
    public let clientVersion: Int32?
    public let createdAt: String?
    public let id: UUID?
    public let ownerId: UUID?
    public let resolvedAt: String?
    public let rowId: UUID?
    public let serverVersion: Int32?
    public let tableName: String?
    public enum CodingKeys: String, CodingKey {
      case clientVersion = "client_version"
      case createdAt = "created_at"
      case id = "id"
      case ownerId = "owner_id"
      case resolvedAt = "resolved_at"
      case rowId = "row_id"
      case serverVersion = "server_version"
      case tableName = "table_name"
    }
  }
  public struct TransactionsSelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let accountKind: AccountKind?
    public let amount: Decimal
    public let categoryId: UUID?
    public let categoryKind: CategoryKind?
    public let createdAt: String
    public let createdBy: UUID
    public let currency: String
    public let deletedAt: String?
    public let externalId: String?
    public let id: UUID
    public let merchantNormalized: String?
    public let merchantRaw: String?
    public let occurredAt: String
    public let ownerId: UUID
    public let recurringRuleId: UUID?
    public let source: TransactionSource
    public let status: TransactionStatus
    public let transferGroupId: UUID?
    public let updatedAt: String
    public let version: Int32
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case accountKind = "account_kind"
      case amount = "amount"
      case categoryId = "category_id"
      case categoryKind = "category_kind"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case externalId = "external_id"
      case id = "id"
      case merchantNormalized = "merchant_normalized"
      case merchantRaw = "merchant_raw"
      case occurredAt = "occurred_at"
      case ownerId = "owner_id"
      case recurringRuleId = "recurring_rule_id"
      case source = "source"
      case status = "status"
      case transferGroupId = "transfer_group_id"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct TransactionsInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let accountKind: AccountKind?
    public let amount: Decimal
    public let categoryId: UUID?
    public let categoryKind: CategoryKind?
    public let createdAt: String?
    public let createdBy: UUID
    public let currency: String
    public let deletedAt: String?
    public let externalId: String?
    public let id: UUID?
    public let merchantNormalized: String?
    public let merchantRaw: String?
    public let occurredAt: String?
    public let ownerId: UUID
    public let recurringRuleId: UUID?
    public let source: TransactionSource?
    public let status: TransactionStatus?
    public let transferGroupId: UUID?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case accountKind = "account_kind"
      case amount = "amount"
      case categoryId = "category_id"
      case categoryKind = "category_kind"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case externalId = "external_id"
      case id = "id"
      case merchantNormalized = "merchant_normalized"
      case merchantRaw = "merchant_raw"
      case occurredAt = "occurred_at"
      case ownerId = "owner_id"
      case recurringRuleId = "recurring_rule_id"
      case source = "source"
      case status = "status"
      case transferGroupId = "transfer_group_id"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct TransactionsUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let accountKind: AccountKind?
    public let amount: Decimal?
    public let categoryId: UUID?
    public let categoryKind: CategoryKind?
    public let createdAt: String?
    public let createdBy: UUID?
    public let currency: String?
    public let deletedAt: String?
    public let externalId: String?
    public let id: UUID?
    public let merchantNormalized: String?
    public let merchantRaw: String?
    public let occurredAt: String?
    public let ownerId: UUID?
    public let recurringRuleId: UUID?
    public let source: TransactionSource?
    public let status: TransactionStatus?
    public let transferGroupId: UUID?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case accountKind = "account_kind"
      case amount = "amount"
      case categoryId = "category_id"
      case categoryKind = "category_kind"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case externalId = "external_id"
      case id = "id"
      case merchantNormalized = "merchant_normalized"
      case merchantRaw = "merchant_raw"
      case occurredAt = "occurred_at"
      case ownerId = "owner_id"
      case recurringRuleId = "recurring_rule_id"
      case source = "source"
      case status = "status"
      case transferGroupId = "transfer_group_id"
      case updatedAt = "updated_at"
      case version = "version"
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
  public struct AccountBalancesBaseSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let balance: Decimal?
    public let balanceBase: Decimal?
    public let baseCurrency: String?
    public let currency: String?
    public let hasMissingRate: Bool?
    public let ownerId: UUID?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case balance = "balance"
      case balanceBase = "balance_base"
      case baseCurrency = "base_currency"
      case currency = "currency"
      case hasMissingRate = "has_missing_rate"
      case ownerId = "owner_id"
    }
  }
  public struct AccountsSyncStatusSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let archivedAt: String?
    public let balance: Decimal?
    public let currency: String?
    public let includeInTotal: Bool?
    public let isStale: Bool?
    public let kind: AccountKind?
    public let lastReconciliationId: UUID?
    public let lastVerifiedAt: String?
    public let minorUnit: Int16?
    public let name: String?
    public let subtype: AccountSubtype?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case archivedAt = "archived_at"
      case balance = "balance"
      case currency = "currency"
      case includeInTotal = "include_in_total"
      case isStale = "is_stale"
      case kind = "kind"
      case lastReconciliationId = "last_reconciliation_id"
      case lastVerifiedAt = "last_verified_at"
      case minorUnit = "minor_unit"
      case name = "name"
      case subtype = "subtype"
    }
  }
  public struct AccountsWithBalancesSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let archivedAt: String?
    public let balance: Decimal?
    public let balanceBase: Decimal?
    public let baseCurrency: String?
    public let baseMinorUnit: Int16?
    public let countsTowardFi: Bool?
    public let currency: String?
    public let hasMissingRate: Bool?
    public let includeInTotal: Bool?
    public let isShared: Bool?
    public let kind: AccountKind?
    public let minorUnit: Int16?
    public let name: String?
    public let subtype: AccountSubtype?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case archivedAt = "archived_at"
      case balance = "balance"
      case balanceBase = "balance_base"
      case baseCurrency = "base_currency"
      case baseMinorUnit = "base_minor_unit"
      case countsTowardFi = "counts_toward_fi"
      case currency = "currency"
      case hasMissingRate = "has_missing_rate"
      case includeInTotal = "include_in_total"
      case isShared = "is_shared"
      case kind = "kind"
      case minorUnit = "minor_unit"
      case name = "name"
      case subtype = "subtype"
      case version = "version"
    }
  }
  public struct NeedsReviewSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let amount: Decimal?
    public let currency: String?
    public let itemId: UUID?
    public let kind: String?
    public let occurredAt: String?
    public let subtitle: String?
    public let title: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case amount = "amount"
      case currency = "currency"
      case itemId = "item_id"
      case kind = "kind"
      case occurredAt = "occurred_at"
      case subtitle = "subtitle"
      case title = "title"
    }
  }
  public struct TransactionsWithDetailsSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let accountName: String?
    public let amount: Decimal?
    public let amountBase: Decimal?
    public let baseCurrency: String?
    public let baseMinorUnit: Int16?
    public let categoryId: UUID?
    public let categoryName: String?
    public let createdAt: String?
    public let createdBy: UUID?
    public let currency: String?
    public let hasMissingRate: Bool?
    public let kind: String?
    public let merchantNormalized: String?
    public let merchantRaw: String?
    public let minorUnit: Int16?
    public let occurredAt: String?
    public let recurringRuleId: UUID?
    public let source: TransactionSource?
    public let status: TransactionStatus?
    public let transactionId: UUID?
    public let transferGroupId: UUID?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case accountName = "account_name"
      case amount = "amount"
      case amountBase = "amount_base"
      case baseCurrency = "base_currency"
      case baseMinorUnit = "base_minor_unit"
      case categoryId = "category_id"
      case categoryName = "category_name"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case hasMissingRate = "has_missing_rate"
      case kind = "kind"
      case merchantNormalized = "merchant_normalized"
      case merchantRaw = "merchant_raw"
      case minorUnit = "minor_unit"
      case occurredAt = "occurred_at"
      case recurringRuleId = "recurring_rule_id"
      case source = "source"
      case status = "status"
      case transactionId = "transaction_id"
      case transferGroupId = "transfer_group_id"
      case version = "version"
    }
  }
}
