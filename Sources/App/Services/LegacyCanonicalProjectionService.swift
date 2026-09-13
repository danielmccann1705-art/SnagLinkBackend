import Vapor
import Fluent
import FluentSQL

/// Internal preparation only. Persist allocations and the projection digest once;
/// rederive all typed values from the unchanged verified source on reload.
enum LegacyCanonicalProjectionService {
    typealias P = LegacyCanonicalProjection
    static func prepare(_ command: LegacyCanonicalProjectionCommand, actor: StagedLegacyImportActor,
                        binding: ImportServerBinding, on database: Database) async throws -> LegacyCanonicalProjectionReceipt {
        guard command.policy == P.policy, command.expectedSourceRevision == 1 else { throw LegacyCanonicalProjectionError.unsupportedPolicy }
        // No transaction spans IO here. This first source read is re-bound under the
        // second current workspace/auth fence; immutable bytes cannot change between.
        let graph = try await StagedLegacyImportService.loadVerifiedGraph(command.scope,actor:actor,binding:binding,on:database)
        let hash = try LegacyCanonicalProjectionMapper.digest(command)
        return try await StagedLegacyImportService.withActiveSession(command.scope,actor:actor,binding:binding,on:database) { source,db in
            guard source.revision == command.expectedSourceRevision, command.operationId != source.createOperationId, command.projectionId != source.sessionId else { throw LegacyCanonicalProjectionError.binding }
            // Dedicated namespace under the source workspace lock, never invert the
            // global mutation lock ordering or reuse a source/file operation receipt.
            try await VerifiedIdentityService.lock("canonical-projection:\(actor.id):\(command.operationId)",on:db)
            let sql = try VerifiedIdentityService.sql(db)
            if let saved = try await sql.raw("SELECT * FROM legacy_canonical_projections WHERE id = \(bind: command.projectionId) OR session_id = \(bind: source.sessionId) OR (actor_id = \(bind: actor.id) AND operation_id = \(bind: command.operationId))").first() {
                guard try saved.decode(column:"id",as:UUID.self) == command.projectionId,
                      try saved.decode(column:"session_id",as:UUID.self) == source.sessionId,
                      try saved.decode(column:"request_hash",as:String.self) == hash else { throw LegacyCanonicalProjectionError.projectionChanged }
                let value = try await build(graph:graph,source:source,projectionID:command.projectionId,on:db)
                try await verify(value,row:saved,on:db)
                return try decodeReceipt(saved)
            }
            let value = try await build(graph:graph,source:source,projectionID:command.projectionId,on:db)
            let checksum = try LegacyCanonicalProjectionMapper.digest(value), now = Date()
            let receipt = LegacyCanonicalProjectionReceipt(projectionId:command.projectionId,sessionId:source.sessionId,operationId:command.operationId,
                policy:P.policy,graphSHA256:checksum,revision:1,createdAt:now,blockerCount:value.findings.filter { $0.disposition == .blocker }.count,
                qualificationCount:value.findings.filter { $0.disposition == .qualification }.count,fileCount:value.files.count,allocationCount:value.allocations.count,importExecutable:false)
            let receiptJSON = String(decoding:try LegacyCanonicalProjectionMapper.encode(receipt),as:UTF8.self)
            try await sql.raw("""
                INSERT INTO legacy_canonical_projections(id,session_id,actor_id,workspace_id,device_id,operation_id,policy,expected_source_revision,request_hash,graph_sha256,receipt_json,state,created_at)
                VALUES(\(bind: command.projectionId),\(bind: source.sessionId),\(bind: actor.id),\(bind: source.workspaceId),\(bind: source.deviceId),\(bind: command.operationId),\(bind: P.policy),1,\(bind: hash),\(bind: checksum),\(bind: receiptJSON),'prepared_non_executable',\(bind: now))
                """).run()
            for allocation in value.allocations {
                try Task.checkCancellation()
                try await sql.raw("INSERT INTO legacy_canonical_allocations(projection_id,allocation_key,target_id) VALUES(\(bind: value.projectionId),\(bind: allocation.key),\(bind: allocation.targetId))").run()
            }
            for directory in value.directoryIdentities {
                let b = value.binding
                let existing = try await directoryRow(directory,binding:b,on:db)
                let id: UUID
                if let existing {
                    guard try existing.decode(column:"intrinsic_sha256",as:String.self) == directory.intrinsicSHA256,
                          try existing.decode(column:"target_id",as:UUID.self) == directory.targetId,
                          try existing.decode(column:"intrinsic_policy",as:String.self) == directory.policy else { throw LegacyCanonicalProjectionError.changedDirectory }
                    id = try existing.decode(column:"id",as:UUID.self)
                } else {
                    id = UUID()
                    try await sql.raw("""
                        INSERT INTO legacy_canonical_directory_identities(id,first_projection_id,actor_id,workspace_id,environment,api_origin,archive_id,source_fingerprint,kind,source_id,target_id,intrinsic_policy,intrinsic_sha256,canonical_reservation)
                        VALUES(\(bind: id),\(bind: value.projectionId),\(bind: b.actorId),\(bind: b.workspaceId),\(bind: b.destination.environment),\(bind: b.destination.apiOrigin),\(bind: b.archiveId),\(bind: b.sourceFingerprint),\(bind: directory.kind.rawValue),\(bind: directory.sourceId),\(bind: directory.targetId),\(bind: directory.policy),\(bind: directory.intrinsicSHA256),'none')
                        """).run()
                }
                try await sql.raw("INSERT INTO legacy_canonical_projection_directories(projection_id,identity_id) VALUES(\(bind: value.projectionId),\(bind: id))").run()
            }
            // withActiveSession's outer cancellation fence checks after this callback
            // and before COMMIT, including cancellation lost by Fluent's task bridge.
            return receipt
        }
    }

    static func read(projectionID: UUID, scope: StagedLegacyImportScope, actor: StagedLegacyImportActor,
                     binding: ImportServerBinding, on database: Database) async throws -> P {
        let graph = try await StagedLegacyImportService.loadVerifiedGraph(scope,actor:actor,binding:binding,on:database)
        return try await StagedLegacyImportService.withActiveSession(scope,actor:actor,binding:binding,on:database,allowPublished:true) { source,db in
            guard let row = try await VerifiedIdentityService.sql(db).raw("SELECT * FROM legacy_canonical_projections WHERE id = \(bind: projectionID) AND session_id = \(bind: scope.sessionId) AND actor_id = \(bind: actor.id)").first() else { throw Abort(.notFound) }
            let value = try await build(graph:graph,source:source,projectionID:projectionID,on:db)
            try await verify(value,row:row,on:db); return value
        }
    }

    private static func build(graph:LegacyProjectImportGraph,source:StagedLegacyImportReceipt,projectionID:UUID,on db:Database) async throws -> P {
        let sql = try VerifiedIdentityService.sql(db)
        let capacity = try await sql.raw("SELECT (SELECT count(*) FROM contractors WHERE workspace_id = \(bind: source.workspaceId) AND platform_managed = true) + (SELECT count(*) FROM trades WHERE workspace_id = \(bind: source.workspaceId) AND platform_managed = true) AS n").first()!.decode(column:"n",as:Int.self)
        let current = try LegacyProjectImportGraphValidator.validate(graph.decoded,capacity:.init(existingWorkspaceDirectoryRows:capacity))
        // The stored graph hash is independent of changing workspace directory size.
        // Use source-stage bound in the immutable value; current capacity is checked
        // above and must be checked again by the future atomic writer.
        let stableGraph = try LegacyProjectImportGraphValidator.validate(graph.decoded,capacity:.init(existingWorkspaceDirectoryRows:source.snapshotRowUpperBound-source.journalEventUpperBound))
        guard current.publicationBudget.journalEventUpperBound == stableGraph.publicationBudget.journalEventUpperBound else { throw LegacyCanonicalProjectionError.capacity }
        let records = try await sql.raw("SELECT kind,source_id,mapping_id,source_sha256 FROM staged_legacy_import_records WHERE session_id = \(bind: source.sessionId)").all().map { row -> P.SourceRecord in
            guard let kind = try LegacyImportRecordKind(rawValue:row.decode(column:"kind",as:String.self)) else { throw LegacyCanonicalProjectionError.allocation }
            return try .init(kind:kind,sourceId:row.decode(column:"source_id",as:UUID.self),mappingId:row.decode(column:"mapping_id",as:UUID.self),sourceSHA256:row.decode(column:"source_sha256",as:String.self))
        }
        let declarations = try await sql.raw("SELECT declaration_id,archive_path,declared_sha256,declared_bytes FROM staged_legacy_import_files WHERE session_id = \(bind: source.sessionId)").all().map { row in
            try LegacyCanonicalProjectionMapper.Declaration(archivePath:row.decode(column:"archive_path",as:String.self),id:row.decode(column:"declaration_id",as:UUID.self),sha256:row.decode(column:"declared_sha256",as:String.self),bytes:row.decode(column:"declared_bytes",as:Int64.self))
        }
        let uses = try await sql.raw("SELECT kind,source_id,role,position,use_id FROM staged_legacy_import_file_uses WHERE session_id = \(bind: source.sessionId)").all().map { row -> LegacyCanonicalProjectionMapper.Use in
            guard let kind = try LegacyImportRecordKind(rawValue:row.decode(column:"kind",as:String.self)),let role = try LegacyImportFileRole(rawValue:row.decode(column:"role",as:String.self)) else { throw LegacyCanonicalProjectionError.allocation }
            return try .init(key:LegacyCanonicalProjectionMapper.useKey(kind,row.decode(column:"source_id",as:UUID.self),role,row.decode(column:"position",as:Int.self)),id:row.decode(column:"use_id",as:UUID.self))
        }
        return try LegacyCanonicalProjectionMapper.map(graph:stableGraph,receipt:source,projectionID:projectionID,records:records,declarations:declarations,uses:uses)
    }
    private static func verify(_ value:P,row:SQLRow,on db:Database) async throws {
        guard try row.decode(column:"graph_sha256",as:String.self) == LegacyCanonicalProjectionMapper.digest(value),
              try row.decode(column:"policy",as:String.self) == P.policy,
              try row.decode(column:"actor_id",as:UUID.self) == value.binding.actorId,
              try row.decode(column:"session_id",as:UUID.self) == value.binding.sessionId,
              try row.decode(column:"expected_source_revision",as:Int64.self) == value.binding.sourceRevision,
              try row.decode(column:"state",as:String.self) == "prepared_non_executable",
              try row.decode(column:"workspace_id",as:UUID.self) == value.binding.workspaceId,
              try row.decode(column:"device_id",as:UUID.self) == value.binding.deviceId else { throw LegacyCanonicalProjectionError.projectionChanged }
        let rows = try await VerifiedIdentityService.sql(db).raw("SELECT allocation_key,target_id FROM legacy_canonical_allocations WHERE projection_id = \(bind: value.projectionId)").all()
        let saved = try rows.map { try P.Allocation(key:$0.decode(column:"allocation_key",as:String.self),targetId:$0.decode(column:"target_id",as:UUID.self)) }.sorted { $0.key < $1.key }
        guard saved == value.allocations else { throw LegacyCanonicalProjectionError.allocation }
        for directory in value.directoryIdentities {
            guard let row = try await directoryRow(directory,binding:value.binding,on:db),
                  try row.decode(column:"intrinsic_sha256",as:String.self) == directory.intrinsicSHA256,
                  try row.decode(column:"target_id",as:UUID.self) == directory.targetId else { throw LegacyCanonicalProjectionError.changedDirectory }
            let identityID = try row.decode(column:"id",as:UUID.self)
            guard try await VerifiedIdentityService.sql(db).raw("SELECT 1 FROM legacy_canonical_projection_directories WHERE projection_id = \(bind: value.projectionId) AND identity_id = \(bind: identityID)").first() != nil else { throw LegacyCanonicalProjectionError.allocation }
        }
        let receipt = try decodeReceipt(row)
        guard receipt.projectionId == value.projectionId, receipt.graphSHA256 == (try LegacyCanonicalProjectionMapper.digest(value)), !receipt.importExecutable else { throw LegacyCanonicalProjectionError.projectionChanged }
    }
    private static func directoryRow(_ d:P.DirectoryIdentity,binding b:P.Binding,on db:Database) async throws -> SQLRow? {
        try await VerifiedIdentityService.sql(db).raw("""
            SELECT * FROM legacy_canonical_directory_identities WHERE actor_id = \(bind: b.actorId) AND workspace_id = \(bind: b.workspaceId)
            AND environment = \(bind: b.destination.environment) AND api_origin = \(bind: b.destination.apiOrigin) AND archive_id = \(bind: b.archiveId)
            AND source_fingerprint = \(bind: b.sourceFingerprint) AND kind = \(bind: d.kind.rawValue) AND source_id = \(bind: d.sourceId)
            """).first()
    }
    private static func decodeReceipt(_ row:SQLRow) throws -> LegacyCanonicalProjectionReceipt {
        try JSONDecoder().decode(LegacyCanonicalProjectionReceipt.self,from:Data(row.decode(column:"receipt_json",as:String.self).utf8))
    }
}
