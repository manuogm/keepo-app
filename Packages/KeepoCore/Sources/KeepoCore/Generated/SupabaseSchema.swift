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
  public enum HouseholdEventKind: String, Codable, Hashable, Sendable {
    case memberJoined = "member_joined"
    case memberLeft = "member_left"
    case memberErased = "member_erased"
  }
  public enum HouseholdInviteStatus: String, Codable, Hashable, Sendable {
    case pending = "pending"
    case accepted = "accepted"
    case revoked = "revoked"
    case expired = "expired"
  }
  public enum ImportCandidateStatus: String, Codable, Hashable, Sendable {
    case pending = "pending"
    case accepted = "accepted"
    case rejected = "rejected"
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
    public let color: String
    public let createdAt: String
    public let createdBy: UUID
    public let currency: String
    public let deletedAt: String?
    public let icon: String
    public let id: UUID
    public let includeInTotal: Bool
    public let kind: AccountKind
    public let name: String
    public let openingBalanceAt: String
    public let openingBalanceE4: Int64
    public let ownerId: UUID
    public let subtype: AccountSubtype
    public let syncSeq: Int64
    public let updatedAt: String
    public let version: Int32
    public enum CodingKeys: String, CodingKey {
      case archivedAt = "archived_at"
      case color = "color"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case icon = "icon"
      case id = "id"
      case includeInTotal = "include_in_total"
      case kind = "kind"
      case name = "name"
      case openingBalanceAt = "opening_balance_at"
      case openingBalanceE4 = "opening_balance_e4"
      case ownerId = "owner_id"
      case subtype = "subtype"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct AccountsInsert: Codable, Hashable, Sendable {
    public let archivedAt: String?
    public let color: String?
    public let createdAt: String?
    public let createdBy: UUID
    public let currency: String
    public let deletedAt: String?
    public let icon: String?
    public let id: UUID?
    public let includeInTotal: Bool?
    public let kind: AccountKind
    public let name: String
    public let openingBalanceAt: String?
    public let openingBalanceE4: Int64?
    public let ownerId: UUID
    public let subtype: AccountSubtype
    public let syncSeq: Int64?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case archivedAt = "archived_at"
      case color = "color"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case icon = "icon"
      case id = "id"
      case includeInTotal = "include_in_total"
      case kind = "kind"
      case name = "name"
      case openingBalanceAt = "opening_balance_at"
      case openingBalanceE4 = "opening_balance_e4"
      case ownerId = "owner_id"
      case subtype = "subtype"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct AccountsUpdate: Codable, Hashable, Sendable {
    public let archivedAt: String?
    public let color: String?
    public let createdAt: String?
    public let createdBy: UUID?
    public let currency: String?
    public let deletedAt: String?
    public let icon: String?
    public let id: UUID?
    public let includeInTotal: Bool?
    public let kind: AccountKind?
    public let name: String?
    public let openingBalanceAt: String?
    public let openingBalanceE4: Int64?
    public let ownerId: UUID?
    public let subtype: AccountSubtype?
    public let syncSeq: Int64?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case archivedAt = "archived_at"
      case color = "color"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case icon = "icon"
      case id = "id"
      case includeInTotal = "include_in_total"
      case kind = "kind"
      case name = "name"
      case openingBalanceAt = "opening_balance_at"
      case openingBalanceE4 = "opening_balance_e4"
      case ownerId = "owner_id"
      case subtype = "subtype"
      case syncSeq = "sync_seq"
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
    public let deletedAt: String?
    public let id: UUID
    public let syncSeq: Int64
    public let valueE4: Int64
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case id = "id"
      case syncSeq = "sync_seq"
      case valueE4 = "value_e4"
    }
  }
  public struct BalanceSnapshotsInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let asOf: String
    public let createdAt: String?
    public let createdBy: UUID
    public let currency: String
    public let deletedAt: String?
    public let id: UUID?
    public let syncSeq: Int64?
    public let valueE4: Int64
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case id = "id"
      case syncSeq = "sync_seq"
      case valueE4 = "value_e4"
    }
  }
  public struct BalanceSnapshotsUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let asOf: String?
    public let createdAt: String?
    public let createdBy: UUID?
    public let currency: String?
    public let deletedAt: String?
    public let id: UUID?
    public let syncSeq: Int64?
    public let valueE4: Int64?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case id = "id"
      case syncSeq = "sync_seq"
      case valueE4 = "value_e4"
    }
  }
  public struct BudgetsSelect: Codable, Hashable, Sendable {
    public let amountE4: Int64
    public let categoryId: UUID?
    public let createdAt: String
    public let currency: String
    public let deletedAt: String?
    public let id: UUID
    public let ownerId: UUID
    public let periodMonth: String
    public let syncSeq: Int64
    public let updatedAt: String
    public let version: Int32
    public enum CodingKeys: String, CodingKey {
      case amountE4 = "amount_e4"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case id = "id"
      case ownerId = "owner_id"
      case periodMonth = "period_month"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct BudgetsInsert: Codable, Hashable, Sendable {
    public let amountE4: Int64
    public let categoryId: UUID?
    public let createdAt: String?
    public let currency: String
    public let deletedAt: String?
    public let id: UUID?
    public let ownerId: UUID
    public let periodMonth: String
    public let syncSeq: Int64?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case amountE4 = "amount_e4"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case id = "id"
      case ownerId = "owner_id"
      case periodMonth = "period_month"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct BudgetsUpdate: Codable, Hashable, Sendable {
    public let amountE4: Int64?
    public let categoryId: UUID?
    public let createdAt: String?
    public let currency: String?
    public let deletedAt: String?
    public let id: UUID?
    public let ownerId: UUID?
    public let periodMonth: String?
    public let syncSeq: Int64?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case amountE4 = "amount_e4"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case currency = "currency"
      case deletedAt = "deleted_at"
      case id = "id"
      case ownerId = "owner_id"
      case periodMonth = "period_month"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct CardMappingsSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let cardIdentifier: String
    public let createdAt: String
    public let deletedAt: String?
    public let id: UUID
    public let ownerId: UUID
    public let syncSeq: Int64
    public let updatedAt: String
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case cardIdentifier = "card_identifier"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
    }
  }
  public struct CardMappingsInsert: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let cardIdentifier: String
    public let createdAt: String?
    public let deletedAt: String?
    public let id: UUID?
    public let ownerId: UUID
    public let syncSeq: Int64?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case cardIdentifier = "card_identifier"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
    }
  }
  public struct CardMappingsUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let cardIdentifier: String?
    public let createdAt: String?
    public let deletedAt: String?
    public let id: UUID?
    public let ownerId: UUID?
    public let syncSeq: Int64?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case cardIdentifier = "card_identifier"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
    }
  }
  public struct CategoriesSelect: Codable, Hashable, Sendable {
    public let color: String
    public let createdAt: String
    public let deletedAt: String?
    public let icon: String
    public let id: UUID
    public let isDefault: Bool
    public let kind: CategoryKind
    public let name: String
    public let ownerId: UUID
    public let syncSeq: Int64
    public let updatedAt: String
    public let version: Int32
    public enum CodingKeys: String, CodingKey {
      case color = "color"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case icon = "icon"
      case id = "id"
      case isDefault = "is_default"
      case kind = "kind"
      case name = "name"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct CategoriesInsert: Codable, Hashable, Sendable {
    public let color: String?
    public let createdAt: String?
    public let deletedAt: String?
    public let icon: String?
    public let id: UUID?
    public let isDefault: Bool?
    public let kind: CategoryKind
    public let name: String
    public let ownerId: UUID
    public let syncSeq: Int64?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case color = "color"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case icon = "icon"
      case id = "id"
      case isDefault = "is_default"
      case kind = "kind"
      case name = "name"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct CategoriesUpdate: Codable, Hashable, Sendable {
    public let color: String?
    public let createdAt: String?
    public let deletedAt: String?
    public let icon: String?
    public let id: UUID?
    public let isDefault: Bool?
    public let kind: CategoryKind?
    public let name: String?
    public let ownerId: UUID?
    public let syncSeq: Int64?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case color = "color"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case icon = "icon"
      case id = "id"
      case isDefault = "is_default"
      case kind = "kind"
      case name = "name"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct CsvImportBatchesSelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let createdAt: String
    public let filename: String
    public let id: UUID
    public let ownerId: UUID
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case createdAt = "created_at"
      case filename = "filename"
      case id = "id"
      case ownerId = "owner_id"
    }
  }
  public struct CsvImportBatchesInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let createdAt: String?
    public let filename: String
    public let id: UUID?
    public let ownerId: UUID
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case createdAt = "created_at"
      case filename = "filename"
      case id = "id"
      case ownerId = "owner_id"
    }
  }
  public struct CsvImportBatchesUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let createdAt: String?
    public let filename: String?
    public let id: UUID?
    public let ownerId: UUID?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case createdAt = "created_at"
      case filename = "filename"
      case id = "id"
      case ownerId = "owner_id"
    }
  }
  public struct CsvImportCandidatesSelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let amountE4: Int64
    public let batchId: UUID
    public let createdAt: String
    public let currency: String
    public let id: UUID
    public let matchedTransactionId: UUID?
    public let merchantNormalized: String?
    public let merchantRaw: String?
    public let occurredAt: String
    public let ownerId: UUID
    public let rawRow: AnyJSON
    public let status: ImportCandidateStatus
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case amountE4 = "amount_e4"
      case batchId = "batch_id"
      case createdAt = "created_at"
      case currency = "currency"
      case id = "id"
      case matchedTransactionId = "matched_transaction_id"
      case merchantNormalized = "merchant_normalized"
      case merchantRaw = "merchant_raw"
      case occurredAt = "occurred_at"
      case ownerId = "owner_id"
      case rawRow = "raw_row"
      case status = "status"
    }
  }
  public struct CsvImportCandidatesInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let amountE4: Int64
    public let batchId: UUID
    public let createdAt: String?
    public let currency: String
    public let id: UUID?
    public let matchedTransactionId: UUID?
    public let merchantNormalized: String?
    public let merchantRaw: String?
    public let occurredAt: String
    public let ownerId: UUID
    public let rawRow: AnyJSON
    public let status: ImportCandidateStatus?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case amountE4 = "amount_e4"
      case batchId = "batch_id"
      case createdAt = "created_at"
      case currency = "currency"
      case id = "id"
      case matchedTransactionId = "matched_transaction_id"
      case merchantNormalized = "merchant_normalized"
      case merchantRaw = "merchant_raw"
      case occurredAt = "occurred_at"
      case ownerId = "owner_id"
      case rawRow = "raw_row"
      case status = "status"
    }
  }
  public struct CsvImportCandidatesUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let amountE4: Int64?
    public let batchId: UUID?
    public let createdAt: String?
    public let currency: String?
    public let id: UUID?
    public let matchedTransactionId: UUID?
    public let merchantNormalized: String?
    public let merchantRaw: String?
    public let occurredAt: String?
    public let ownerId: UUID?
    public let rawRow: AnyJSON?
    public let status: ImportCandidateStatus?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case amountE4 = "amount_e4"
      case batchId = "batch_id"
      case createdAt = "created_at"
      case currency = "currency"
      case id = "id"
      case matchedTransactionId = "matched_transaction_id"
      case merchantNormalized = "merchant_normalized"
      case merchantRaw = "merchant_raw"
      case occurredAt = "occurred_at"
      case ownerId = "owner_id"
      case rawRow = "raw_row"
      case status = "status"
    }
  }
  public struct CurrenciesSelect: Codable, Hashable, Sendable {
    public let code: String
    public let minorUnit: Int16
    public let syncSeq: Int64
    public enum CodingKeys: String, CodingKey {
      case code = "code"
      case minorUnit = "minor_unit"
      case syncSeq = "sync_seq"
    }
  }
  public struct CurrenciesInsert: Codable, Hashable, Sendable {
    public let code: String
    public let minorUnit: Int16
    public let syncSeq: Int64?
    public enum CodingKeys: String, CodingKey {
      case code = "code"
      case minorUnit = "minor_unit"
      case syncSeq = "sync_seq"
    }
  }
  public struct CurrenciesUpdate: Codable, Hashable, Sendable {
    public let code: String?
    public let minorUnit: Int16?
    public let syncSeq: Int64?
    public enum CodingKeys: String, CodingKey {
      case code = "code"
      case minorUnit = "minor_unit"
      case syncSeq = "sync_seq"
    }
  }
  public struct ExportAuditLogSelect: Codable, Hashable, Sendable {
    public let accountIds: [UUID]
    public let exportedAt: String
    public let id: UUID
    public let ownerId: UUID
    public let rowCount: Int32
    public enum CodingKeys: String, CodingKey {
      case accountIds = "account_ids"
      case exportedAt = "exported_at"
      case id = "id"
      case ownerId = "owner_id"
      case rowCount = "row_count"
    }
  }
  public struct ExportAuditLogInsert: Codable, Hashable, Sendable {
    public let accountIds: [UUID]
    public let exportedAt: String?
    public let id: UUID?
    public let ownerId: UUID
    public let rowCount: Int32
    public enum CodingKeys: String, CodingKey {
      case accountIds = "account_ids"
      case exportedAt = "exported_at"
      case id = "id"
      case ownerId = "owner_id"
      case rowCount = "row_count"
    }
  }
  public struct ExportAuditLogUpdate: Codable, Hashable, Sendable {
    public let accountIds: [UUID]?
    public let exportedAt: String?
    public let id: UUID?
    public let ownerId: UUID?
    public let rowCount: Int32?
    public enum CodingKeys: String, CodingKey {
      case accountIds = "account_ids"
      case exportedAt = "exported_at"
      case id = "id"
      case ownerId = "owner_id"
      case rowCount = "row_count"
    }
  }
  public struct ForkHandledTablesSelect: Codable, Hashable, Sendable {
    public let handling: String
    public let tableName: String
    public enum CodingKeys: String, CodingKey {
      case handling = "handling"
      case tableName = "table_name"
    }
  }
  public struct ForkHandledTablesInsert: Codable, Hashable, Sendable {
    public let handling: String
    public let tableName: String
    public enum CodingKeys: String, CodingKey {
      case handling = "handling"
      case tableName = "table_name"
    }
  }
  public struct ForkHandledTablesUpdate: Codable, Hashable, Sendable {
    public let handling: String?
    public let tableName: String?
    public enum CodingKeys: String, CodingKey {
      case handling = "handling"
      case tableName = "table_name"
    }
  }
  public struct FxRatesSelect: Codable, Hashable, Sendable {
    public let currency: String
    public let fetchedAt: String
    public let rateDate: String
    public let rateToEur: Decimal
    public let source: FxSource
    public let syncSeq: Int64
    public enum CodingKeys: String, CodingKey {
      case currency = "currency"
      case fetchedAt = "fetched_at"
      case rateDate = "rate_date"
      case rateToEur = "rate_to_eur"
      case source = "source"
      case syncSeq = "sync_seq"
    }
  }
  public struct FxRatesInsert: Codable, Hashable, Sendable {
    public let currency: String
    public let fetchedAt: String?
    public let rateDate: String
    public let rateToEur: Decimal
    public let source: FxSource
    public let syncSeq: Int64?
    public enum CodingKeys: String, CodingKey {
      case currency = "currency"
      case fetchedAt = "fetched_at"
      case rateDate = "rate_date"
      case rateToEur = "rate_to_eur"
      case source = "source"
      case syncSeq = "sync_seq"
    }
  }
  public struct FxRatesUpdate: Codable, Hashable, Sendable {
    public let currency: String?
    public let fetchedAt: String?
    public let rateDate: String?
    public let rateToEur: Decimal?
    public let source: FxSource?
    public let syncSeq: Int64?
    public enum CodingKeys: String, CodingKey {
      case currency = "currency"
      case fetchedAt = "fetched_at"
      case rateDate = "rate_date"
      case rateToEur = "rate_to_eur"
      case source = "source"
      case syncSeq = "sync_seq"
    }
  }
  public struct HouseholdAccountsSelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let deletedAt: String?
    public let householdId: UUID
    public let sharedAt: String
    public let syncSeq: Int64
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case deletedAt = "deleted_at"
      case householdId = "household_id"
      case sharedAt = "shared_at"
      case syncSeq = "sync_seq"
    }
  }
  public struct HouseholdAccountsInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let deletedAt: String?
    public let householdId: UUID
    public let sharedAt: String?
    public let syncSeq: Int64?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case deletedAt = "deleted_at"
      case householdId = "household_id"
      case sharedAt = "shared_at"
      case syncSeq = "sync_seq"
    }
  }
  public struct HouseholdAccountsUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let deletedAt: String?
    public let householdId: UUID?
    public let sharedAt: String?
    public let syncSeq: Int64?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case deletedAt = "deleted_at"
      case householdId = "household_id"
      case sharedAt = "shared_at"
      case syncSeq = "sync_seq"
    }
  }
  public struct HouseholdEventsSelect: Codable, Hashable, Sendable {
    public let actorId: UUID
    public let createdAt: String
    public let householdId: UUID
    public let id: UUID
    public let kind: HouseholdEventKind
    public enum CodingKeys: String, CodingKey {
      case actorId = "actor_id"
      case createdAt = "created_at"
      case householdId = "household_id"
      case id = "id"
      case kind = "kind"
    }
  }
  public struct HouseholdEventsInsert: Codable, Hashable, Sendable {
    public let actorId: UUID
    public let createdAt: String?
    public let householdId: UUID
    public let id: UUID?
    public let kind: HouseholdEventKind
    public enum CodingKeys: String, CodingKey {
      case actorId = "actor_id"
      case createdAt = "created_at"
      case householdId = "household_id"
      case id = "id"
      case kind = "kind"
    }
  }
  public struct HouseholdEventsUpdate: Codable, Hashable, Sendable {
    public let actorId: UUID?
    public let createdAt: String?
    public let householdId: UUID?
    public let id: UUID?
    public let kind: HouseholdEventKind?
    public enum CodingKeys: String, CodingKey {
      case actorId = "actor_id"
      case createdAt = "created_at"
      case householdId = "household_id"
      case id = "id"
      case kind = "kind"
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
    public let deletedAt: String?
    public let householdId: UUID
    public let joinedAt: String
    public let syncSeq: Int64
    public let userId: UUID
    public enum CodingKeys: String, CodingKey {
      case deletedAt = "deleted_at"
      case householdId = "household_id"
      case joinedAt = "joined_at"
      case syncSeq = "sync_seq"
      case userId = "user_id"
    }
  }
  public struct HouseholdMembersInsert: Codable, Hashable, Sendable {
    public let deletedAt: String?
    public let householdId: UUID
    public let joinedAt: String?
    public let syncSeq: Int64?
    public let userId: UUID
    public enum CodingKeys: String, CodingKey {
      case deletedAt = "deleted_at"
      case householdId = "household_id"
      case joinedAt = "joined_at"
      case syncSeq = "sync_seq"
      case userId = "user_id"
    }
  }
  public struct HouseholdMembersUpdate: Codable, Hashable, Sendable {
    public let deletedAt: String?
    public let householdId: UUID?
    public let joinedAt: String?
    public let syncSeq: Int64?
    public let userId: UUID?
    public enum CodingKeys: String, CodingKey {
      case deletedAt = "deleted_at"
      case householdId = "household_id"
      case joinedAt = "joined_at"
      case syncSeq = "sync_seq"
      case userId = "user_id"
    }
  }
  public struct HouseholdsSelect: Codable, Hashable, Sendable {
    public let createdAt: String
    public let deletedAt: String?
    public let id: UUID
    public let syncSeq: Int64
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case syncSeq = "sync_seq"
    }
  }
  public struct HouseholdsInsert: Codable, Hashable, Sendable {
    public let createdAt: String?
    public let deletedAt: String?
    public let id: UUID?
    public let syncSeq: Int64?
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case syncSeq = "sync_seq"
    }
  }
  public struct HouseholdsUpdate: Codable, Hashable, Sendable {
    public let createdAt: String?
    public let deletedAt: String?
    public let id: UUID?
    public let syncSeq: Int64?
    public enum CodingKeys: String, CodingKey {
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case syncSeq = "sync_seq"
    }
  }
  public struct MerchantCategoryMapSelect: Codable, Hashable, Sendable {
    public let categoryId: UUID
    public let deletedAt: String?
    public let merchantPattern: String
    public let ownerId: UUID
    public let syncSeq: Int64
    public let updatedAt: String
    public enum CodingKeys: String, CodingKey {
      case categoryId = "category_id"
      case deletedAt = "deleted_at"
      case merchantPattern = "merchant_pattern"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
    }
  }
  public struct MerchantCategoryMapInsert: Codable, Hashable, Sendable {
    public let categoryId: UUID
    public let deletedAt: String?
    public let merchantPattern: String
    public let ownerId: UUID
    public let syncSeq: Int64?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case categoryId = "category_id"
      case deletedAt = "deleted_at"
      case merchantPattern = "merchant_pattern"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
    }
  }
  public struct MerchantCategoryMapUpdate: Codable, Hashable, Sendable {
    public let categoryId: UUID?
    public let deletedAt: String?
    public let merchantPattern: String?
    public let ownerId: UUID?
    public let syncSeq: Int64?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case categoryId = "category_id"
      case deletedAt = "deleted_at"
      case merchantPattern = "merchant_pattern"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
    }
  }
  public struct NetWorthDailySelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let asOf: String
    public let balanceE4: Int64?
    public let currency: String
    public let ownerId: UUID
    public let updatedAt: String
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case balanceE4 = "balance_e4"
      case currency = "currency"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
    }
  }
  public struct NetWorthDailyInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let asOf: String
    public let balanceE4: Int64?
    public let currency: String
    public let ownerId: UUID
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case balanceE4 = "balance_e4"
      case currency = "currency"
      case ownerId = "owner_id"
      case updatedAt = "updated_at"
    }
  }
  public struct NetWorthDailyUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let asOf: String?
    public let balanceE4: Int64?
    public let currency: String?
    public let ownerId: UUID?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case asOf = "as_of"
      case balanceE4 = "balance_e4"
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
    public let deletedAt: String?
    public let id: UUID
    public let onboardedAt: String?
    public let syncEpoch: Int64
    public let syncSeq: Int64
    public let updatedAt: String
    public enum CodingKeys: String, CodingKey {
      case baseCurrency = "base_currency"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case onboardedAt = "onboarded_at"
      case syncEpoch = "sync_epoch"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
    }
  }
  public struct ProfilesInsert: Codable, Hashable, Sendable {
    public let baseCurrency: String?
    public let createdAt: String?
    public let deletedAt: String?
    public let id: UUID
    public let onboardedAt: String?
    public let syncEpoch: Int64?
    public let syncSeq: Int64?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case baseCurrency = "base_currency"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case onboardedAt = "onboarded_at"
      case syncEpoch = "sync_epoch"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
    }
  }
  public struct ProfilesUpdate: Codable, Hashable, Sendable {
    public let baseCurrency: String?
    public let createdAt: String?
    public let deletedAt: String?
    public let id: UUID?
    public let onboardedAt: String?
    public let syncEpoch: Int64?
    public let syncSeq: Int64?
    public let updatedAt: String?
    public enum CodingKeys: String, CodingKey {
      case baseCurrency = "base_currency"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case onboardedAt = "onboarded_at"
      case syncEpoch = "sync_epoch"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
    }
  }
  public struct RecurringRulesSelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let active: Bool
    public let amountE4: Int64
    public let categoryId: UUID
    public let createdAt: String
    public let createdBy: UUID
    public let currency: String
    public let frequency: RecurringFrequency
    public let id: UUID
    public let lastMaterializedAt: String?
    public let nextDueAt: String
    public let ownerId: UUID
    public let syncSeq: Int64
    public let updatedAt: String
    public let version: Int32
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case active = "active"
      case amountE4 = "amount_e4"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case frequency = "frequency"
      case id = "id"
      case lastMaterializedAt = "last_materialized_at"
      case nextDueAt = "next_due_at"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct RecurringRulesInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let active: Bool?
    public let amountE4: Int64
    public let categoryId: UUID
    public let createdAt: String?
    public let createdBy: UUID
    public let currency: String
    public let frequency: RecurringFrequency
    public let id: UUID?
    public let lastMaterializedAt: String?
    public let nextDueAt: String
    public let ownerId: UUID
    public let syncSeq: Int64?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case active = "active"
      case amountE4 = "amount_e4"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case frequency = "frequency"
      case id = "id"
      case lastMaterializedAt = "last_materialized_at"
      case nextDueAt = "next_due_at"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct RecurringRulesUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let active: Bool?
    public let amountE4: Int64?
    public let categoryId: UUID?
    public let createdAt: String?
    public let createdBy: UUID?
    public let currency: String?
    public let frequency: RecurringFrequency?
    public let id: UUID?
    public let lastMaterializedAt: String?
    public let nextDueAt: String?
    public let ownerId: UUID?
    public let syncSeq: Int64?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case active = "active"
      case amountE4 = "amount_e4"
      case categoryId = "category_id"
      case createdAt = "created_at"
      case createdBy = "created_by"
      case currency = "currency"
      case frequency = "frequency"
      case id = "id"
      case lastMaterializedAt = "last_materialized_at"
      case nextDueAt = "next_due_at"
      case ownerId = "owner_id"
      case syncSeq = "sync_seq"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct SyncConflictsSelect: Codable, Hashable, Sendable {
    public let clientVersion: Int32
    public let createdAt: String
    public let deletedAt: String?
    public let id: UUID
    public let ownerId: UUID
    public let resolvedAt: String?
    public let rowId: UUID
    public let serverVersion: Int32
    public let syncSeq: Int64
    public let tableName: String
    public enum CodingKeys: String, CodingKey {
      case clientVersion = "client_version"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case ownerId = "owner_id"
      case resolvedAt = "resolved_at"
      case rowId = "row_id"
      case serverVersion = "server_version"
      case syncSeq = "sync_seq"
      case tableName = "table_name"
    }
  }
  public struct SyncConflictsInsert: Codable, Hashable, Sendable {
    public let clientVersion: Int32
    public let createdAt: String?
    public let deletedAt: String?
    public let id: UUID?
    public let ownerId: UUID
    public let resolvedAt: String?
    public let rowId: UUID
    public let serverVersion: Int32
    public let syncSeq: Int64?
    public let tableName: String
    public enum CodingKeys: String, CodingKey {
      case clientVersion = "client_version"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case ownerId = "owner_id"
      case resolvedAt = "resolved_at"
      case rowId = "row_id"
      case serverVersion = "server_version"
      case syncSeq = "sync_seq"
      case tableName = "table_name"
    }
  }
  public struct SyncConflictsUpdate: Codable, Hashable, Sendable {
    public let clientVersion: Int32?
    public let createdAt: String?
    public let deletedAt: String?
    public let id: UUID?
    public let ownerId: UUID?
    public let resolvedAt: String?
    public let rowId: UUID?
    public let serverVersion: Int32?
    public let syncSeq: Int64?
    public let tableName: String?
    public enum CodingKeys: String, CodingKey {
      case clientVersion = "client_version"
      case createdAt = "created_at"
      case deletedAt = "deleted_at"
      case id = "id"
      case ownerId = "owner_id"
      case resolvedAt = "resolved_at"
      case rowId = "row_id"
      case serverVersion = "server_version"
      case syncSeq = "sync_seq"
      case tableName = "table_name"
    }
  }
  public struct SyncTicketsSelect: Codable, Hashable, Sendable {
    public let domainId: UUID
    public let nextTicket: Int64
    public enum CodingKeys: String, CodingKey {
      case domainId = "domain_id"
      case nextTicket = "next_ticket"
    }
  }
  public struct SyncTicketsInsert: Codable, Hashable, Sendable {
    public let domainId: UUID
    public let nextTicket: Int64?
    public enum CodingKeys: String, CodingKey {
      case domainId = "domain_id"
      case nextTicket = "next_ticket"
    }
  }
  public struct SyncTicketsUpdate: Codable, Hashable, Sendable {
    public let domainId: UUID?
    public let nextTicket: Int64?
    public enum CodingKeys: String, CodingKey {
      case domainId = "domain_id"
      case nextTicket = "next_ticket"
    }
  }
  public struct TransactionsSelect: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let accountKind: AccountKind?
    public let amountE4: Int64
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
    public let syncSeq: Int64
    public let transferGroupId: UUID?
    public let updatedAt: String
    public let version: Int32
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case accountKind = "account_kind"
      case amountE4 = "amount_e4"
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
      case syncSeq = "sync_seq"
      case transferGroupId = "transfer_group_id"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct TransactionsInsert: Codable, Hashable, Sendable {
    public let accountId: UUID
    public let accountKind: AccountKind?
    public let amountE4: Int64
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
    public let syncSeq: Int64?
    public let transferGroupId: UUID?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case accountKind = "account_kind"
      case amountE4 = "amount_e4"
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
      case syncSeq = "sync_seq"
      case transferGroupId = "transfer_group_id"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct TransactionsUpdate: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let accountKind: AccountKind?
    public let amountE4: Int64?
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
    public let syncSeq: Int64?
    public let transferGroupId: UUID?
    public let updatedAt: String?
    public let version: Int32?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case accountKind = "account_kind"
      case amountE4 = "amount_e4"
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
      case syncSeq = "sync_seq"
      case transferGroupId = "transfer_group_id"
      case updatedAt = "updated_at"
      case version = "version"
    }
  }
  public struct AccountBalancesSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let balanceE4: Int64?
    public let currency: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case balanceE4 = "balance_e4"
      case currency = "currency"
    }
  }
  public struct AccountBalancesBaseSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let balanceBaseE4: Int64?
    public let balanceE4: Int64?
    public let baseCurrency: String?
    public let currency: String?
    public let hasMissingRate: Bool?
    public let ownerId: UUID?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case balanceBaseE4 = "balance_base_e4"
      case balanceE4 = "balance_e4"
      case baseCurrency = "base_currency"
      case currency = "currency"
      case hasMissingRate = "has_missing_rate"
      case ownerId = "owner_id"
    }
  }
  public struct AccountsWithBalancesSelect: Codable, Hashable, Sendable {
    public let accountId: UUID?
    public let archivedAt: String?
    public let balanceBaseE4: Int64?
    public let balanceE4: Int64?
    public let baseCurrency: String?
    public let baseMinorUnit: Int16?
    public let color: String?
    public let currency: String?
    public let hasMissingRate: Bool?
    public let icon: String?
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
      case balanceBaseE4 = "balance_base_e4"
      case balanceE4 = "balance_e4"
      case baseCurrency = "base_currency"
      case baseMinorUnit = "base_minor_unit"
      case color = "color"
      case currency = "currency"
      case hasMissingRate = "has_missing_rate"
      case icon = "icon"
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
    public let amountE4: Int64?
    public let currency: String?
    public let itemId: UUID?
    public let kind: String?
    public let occurredAt: String?
    public let subtitle: String?
    public let title: String?
    public enum CodingKeys: String, CodingKey {
      case accountId = "account_id"
      case amountE4 = "amount_e4"
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
    public let amountBaseE4: Int64?
    public let amountE4: Int64?
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
      case amountBaseE4 = "amount_base_e4"
      case amountE4 = "amount_e4"
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
