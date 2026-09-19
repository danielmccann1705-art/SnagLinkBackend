import Fluent
import FluentSQL
import Foundation
import Vapor

enum CompletionUploadObjectService {
    enum Principal: Sendable, Equatable {
        case user(UUID)
        case link(id: UUID, projectID: UUID, creatorID: UUID)
    }

    struct Allocation: Sendable {
        let id: UUID
        let storageKey: String
        let thumbnailKey: String
        let issuedURL: String
        let plannedThumbnailURL: String
        let filename: String
        let contentType: String
        let fileSize: Int
        let principal: Principal
    }

    static func allocate(principal: Principal, fileExtension: String, contentType: String,
                         fileSize: Int, on database: Database) async throws -> Allocation {
        guard ["jpg","jpeg","png","heic","heif"].contains(fileExtension),
              (1...(10 * 1024 * 1024)).contains(fileSize) else {
            throw Abort(.badRequest, reason: "Invalid completion upload metadata")
        }
        let id=UUID(), filename="\(id.uuidString).\(fileExtension)"
        let key="uploads/photos/\(filename)", thumbnailKey="uploads/photos/thumb_\(filename)"
        let base=StorageService.publicBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let allocation=Allocation(id:id,storageKey:key,thumbnailKey:thumbnailKey,issuedURL:"\(base)/\(key)",
                                  plannedThumbnailURL:"\(base)/\(thumbnailKey)",filename:filename,
                                  contentType:contentType,fileSize:fileSize,principal:principal)
        try await database.transaction { db in
            try await authorize(principal, on: db)
            let sql=try VerifiedIdentityService.sql(db)
            switch principal {
            case .user(let userID):
                try await sql.raw("""
                    INSERT INTO completion_upload_objects(id,storage_key,thumbnail_key,issued_url,filename,content_type,file_size,
                        uploaded_by_user_id,state,created_at)
                    VALUES(\(bind:id),\(bind:key),\(bind:thumbnailKey),\(bind:allocation.issuedURL),\(bind:filename),
                        \(bind:contentType),\(bind:fileSize),\(bind:userID),'allocated',NOW())
                    """).run()
            case .link(let linkID,let projectID,_):
                try await sql.raw("""
                    INSERT INTO completion_upload_objects(id,storage_key,thumbnail_key,issued_url,filename,content_type,file_size,
                        magic_link_id,project_id,state,created_at)
                    VALUES(\(bind:id),\(bind:key),\(bind:thumbnailKey),\(bind:allocation.issuedURL),\(bind:filename),
                        \(bind:contentType),\(bind:fileSize),\(bind:linkID),\(bind:projectID),'allocated',NOW())
                    """).run()
            }
        }
        return allocation
    }

    /// Call at the start of the transaction which performs both storage writes.
    /// The user/link share locks must remain held until `markReady` commits.
    static func lockForWrite(_ allocation: Allocation, on database: Database) async throws {
        try await authorize(allocation.principal, on: database)
        let sql=try VerifiedIdentityService.sql(database)
        let row: SQLRow?
        switch allocation.principal {
        case .user(let userID):
            row=try await sql.raw("SELECT id FROM completion_upload_objects WHERE id=\(bind:allocation.id) AND uploaded_by_user_id=\(bind:userID) AND state='allocated' FOR UPDATE").first()
        case .link(let linkID,let projectID,_):
            row=try await sql.raw("SELECT id FROM completion_upload_objects WHERE id=\(bind:allocation.id) AND magic_link_id=\(bind:linkID) AND project_id=\(bind:projectID) AND state='allocated' FOR UPDATE").first()
        }
        guard row != nil else { throw Abort(.conflict, reason: "Completion upload is unavailable", identifier: "completion_upload_unavailable") }
    }

    static func markReady(_ allocation: Allocation, thumbnailReady: Bool, on database: Database) async throws {
        let thumbnailURL=thumbnailReady ? allocation.plannedThumbnailURL : allocation.issuedURL
        guard try await VerifiedIdentityService.sql(database).raw("""
            UPDATE completion_upload_objects SET state='ready',thumbnail_ready=\(bind:thumbnailReady),
                issued_thumbnail_url=\(bind:thumbnailURL),ready_at=NOW()
            WHERE id=\(bind:allocation.id) AND state='allocated' RETURNING id
            """).first() != nil else {
            throw Abort(.conflict, reason: "Completion upload is unavailable", identifier: "completion_upload_unavailable")
        }
    }

    /// Converts exact URLs issued to this same link into stable completion-photo
    /// rows. An unregistered, JWT-owned or other-link URL is never attached.
    static func attach(urls: [String], completionID: UUID, link: MagicLink, on database: Database) async throws {
        guard let linkID=link.id else { throw Abort(.badRequest, reason: "Invalid Contractor link") }
        let principal=Principal.link(id:linkID,projectID:link.projectId,creatorID:link.createdById)
        try await authorize(principal,on:database)
        guard Set(urls).count==urls.count else { throw Abort(.badRequest, reason: "A completion photo was repeated", identifier: "invalid_completion_photo_reference") }
        let sql=try VerifiedIdentityService.sql(database)
        var rows:[(String,SQLRow)]=[]
        for url in urls.sorted() {
            guard let row=try await sql.raw("""
                SELECT id,issued_url,issued_thumbnail_url,filename,content_type,file_size
                FROM completion_upload_objects
                WHERE issued_url=\(bind:url) AND magic_link_id=\(bind:linkID) AND project_id=\(bind:link.projectId)
                    AND state='ready' FOR UPDATE
                """).first() else {
                throw Abort(.badRequest, reason: "Completion photo was not issued to this Contractor link", identifier: "invalid_completion_photo_reference")
            }
            rows.append((url,row))
        }
        for (_,row) in rows {
            let id=try row.decode(column:"id",as:UUID.self)
            let issuedURL=try row.decode(column:"issued_url",as:String.self)
            let thumbnailURL=try row.decode(column:"issued_thumbnail_url",as:String.self)
            let filename=try row.decode(column:"filename",as:String.self)
            let contentType=try row.decode(column:"content_type",as:String.self)
            let fileSize=try row.decode(column:"file_size",as:Int.self)
            try await sql.raw("""
                INSERT INTO completion_photos(id,completion_id,url,thumbnail_url,filename,content_type,file_size,uploaded_at,upload_object_id)
                VALUES(\(bind:id),\(bind:completionID),\(bind:issuedURL),\(bind:thumbnailURL),\(bind:filename),
                    \(bind:contentType),\(bind:fileSize),NOW(),\(bind:id))
                """).run()
            try await sql.raw("UPDATE completion_upload_objects SET state='attached',attached_at=NOW() WHERE id=\(bind:id) AND state='ready'").run()
        }
    }

    private static func authorize(_ principal: Principal, on database: Database) async throws {
        let sql=try VerifiedIdentityService.sql(database)
        switch principal {
        case .user(let userID):
            guard try await sql.raw("SELECT id FROM users WHERE id=\(bind:userID) AND lifecycle_state='active' FOR SHARE").first() != nil else {
                throw Abort(.unauthorized, reason: "Account is no longer available")
            }
        case .link(let linkID,let projectID,let creatorID):
            guard try await sql.raw("SELECT id FROM users WHERE id=\(bind:creatorID) AND lifecycle_state='active' FOR SHARE").first() != nil,
                  try await sql.raw("""
                    SELECT id FROM magic_links WHERE id=\(bind:linkID) AND project_id=\(bind:projectID)
                        AND created_by_id=\(bind:creatorID) AND revoked_at IS NULL AND expires_at>CURRENT_TIMESTAMP
                        AND preview_mode=FALSE AND access_level IN ('update','full') FOR SHARE
                    """).first() != nil else {
                throw Abort(.forbidden, reason: "This Contractor link cannot upload completion photos")
            }
        }
    }
}
