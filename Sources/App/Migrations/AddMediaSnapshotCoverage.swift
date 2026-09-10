import Fluent

struct AddMediaSnapshotCoverage: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await VerifiedIdentityService.sql(database).raw("ALTER TABLE register_snapshots ADD COLUMN coverage TEXT[] NOT NULL DEFAULT ARRAY['project', 'snags', 'contractors', 'trades']::TEXT[]").run()
    }
    func revert(on database: Database) async throws {
        // Previous compatible readers ignore this additive field.
    }
}
