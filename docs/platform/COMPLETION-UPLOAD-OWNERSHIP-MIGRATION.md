# Completion upload ownership migration compatibility

`CreateCompletionUploadObjects` deliberately does not backfill historical
`completion_photos` URLs. Those strings were supplied by clients and cannot prove
who owns the referenced object. Account deletion therefore continues to record
them as unresolved and blocks the deletion receipt until independent evidence is
available.

The migration adds a nullable ownership column so those historical rows remain
readable. It also installs a database trigger which requires every **new**
`completion_photos` row to match a ready server-issued upload record, including
the stable ID, exact URLs and metadata, Contractor link and project. Old server
binaries cannot insert unledgered completion references after the migration is
committed; their legacy insert fails closed. Deploy the migration and compatible
application image as one release, and do not remove the trigger for a rolling
transition.

Allocated records survive upload, authentication and process failures. No timed
cleanup or historical ownership inference is introduced. If storage accepts an
object but the final authentication check or database commit fails, the allocated
row retains its exact original and thumbnail keys for later evidence-based cleanup.
