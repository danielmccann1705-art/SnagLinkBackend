import Vapor
import Fluent

struct CreateOwnershipTransferOffers: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.transaction { db in
            let sql = try VerifiedIdentityService.sql(db)
            try await sql.raw("""
                CREATE TABLE ownership_transfer_offers (
                    id UUID PRIMARY KEY, workspace_id UUID NOT NULL REFERENCES teams(id),
                    owner_user_id UUID NOT NULL REFERENCES users(id), target_user_id UUID NOT NULL REFERENCES users(id),
                    workspace_revision BIGINT NOT NULL, target_membership_revision BIGINT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('pending','accepted','declined','cancelled','superseded')),
                    created_at TIMESTAMPTZ NOT NULL, resolved_at TIMESTAMPTZ,
                    CHECK(owner_user_id<>target_user_id), CHECK((state='pending')=(resolved_at IS NULL))
                )
                """).run()
            try await sql.raw("CREATE UNIQUE INDEX ownership_transfer_pending ON ownership_transfer_offers(workspace_id) WHERE state='pending'").run()
            try await sql.raw("CREATE INDEX ownership_transfer_recipient ON ownership_transfer_offers(target_user_id,state)").run()
            try await sql.raw("""
                CREATE FUNCTION require_active_transfer_parties() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.state='pending' THEN
                        PERFORM id FROM users WHERE id IN (NEW.owner_user_id,NEW.target_user_id) ORDER BY id FOR SHARE;
                        IF (SELECT COUNT(*) FROM users WHERE id IN (NEW.owner_user_id,NEW.target_user_id) AND lifecycle_state='active')<>2 THEN
                            RAISE EXCEPTION 'Transfer party unavailable' USING ERRCODE='23514';
                        END IF;
                    END IF;
                    RETURN NEW;
                END $$
                """).run()
            try await sql.raw("CREATE TRIGGER ownership_transfer_active_parties BEFORE INSERT OR UPDATE ON ownership_transfer_offers FOR EACH ROW EXECUTE FUNCTION require_active_transfer_parties()").run()
        }
    }
    func revert(on database: Database) async throws {
        throw Abort(.conflict, reason: "Ownership acceptance is persistent; use a compatible image")
    }
}
