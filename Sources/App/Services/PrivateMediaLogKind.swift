import Foundation

/// The complete operator vocabulary for a private photograph's bytes: one `kind`
/// per line, from this list, and nothing else.
///
/// **Why it is closed.** A storage error's own words can carry a key, an ETag, a
/// bucket, a namespace or a credential. None of those may reach a log — a log is
/// read by more people, and kept in more places, than the bucket it describes.
/// So the writer and the reader each choose a fixed word here at the call site
/// and discard what the store said.
///
/// **Why it is shared.** The read path and the write path split the same four
/// storage outcomes at different moments, and two of them mean the same thing on
/// both sides. `absent` and `not_landed` are the same physical observation —
/// nothing is at the address — read once as "the object a reader is entitled to
/// is gone" and once as "the PUT never landed, a retry will help". Keeping them
/// in one enum is what makes that relationship visible rather than a coincidence
/// between two lists that drift.
///
/// None of these reaches a client. Each of the four write kinds sits behind one
/// 503 `media_unavailable`, and both read kinds behind the same; the split exists
/// for the operator, who needs to know whether to retry or to look at storage,
/// and is deliberately invisible to a reader, who must learn nothing about the
/// shape of the bucket behind their photograph.
enum PrivateMediaLogKind: String, Sendable, Equatable, CaseIterable {

    // MARK: - Reading (B3)

    /// There is nothing at the address. Decided from the GET's status line,
    /// before any body handling.
    case absent

    // MARK: - Writing (B2)

    /// Row 8a. The address was already taken and then answered "nothing is
    /// here". Two facts that cannot both be true; storage is not to be trusted
    /// yet.
    case existsThenAbsent = "exists_then_absent"

    /// Row 8b. The address was already taken and the readback did not answer.
    case readbackUnavailable = "readback_unavailable"

    /// Row 14a. The PUT's outcome was unknown and nothing is at the address: the
    /// write never landed. This is the row the readback was built for — it is the
    /// one that says a retry will help.
    case notLanded = "not_landed"

    // MARK: - Both

    /// Row 14b on the write path; a GET that did not answer, or answered
    /// something that could not be read, on the read path. Storage itself is the
    /// thing that is wrong.
    case storageUnreachable = "storage_unreachable"
}
