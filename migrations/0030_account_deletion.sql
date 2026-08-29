-- Identity/account lifecycle: durable suppression after the distinguished
-- owner deletes their account.
--
-- A missing owner row is normally bootstrapped automatically for the static
-- MCP bearer. Account deletion must be different: the user's personal rows are
-- physically removed, while this singleton remembers that the owner role was
-- deliberately deleted so MCP/bootstrap paths cannot silently recreate it or
-- promote the earliest remaining member. The Apple subject is retained only
-- as a one-way SHA-256 digest so a later Sign in with Apple attempt by the same
-- identity can receive an explicit account-deleted response. Administrative
-- recovery is an intentional D1 operation that removes this row.

CREATE TABLE IF NOT EXISTS owner_deletion_tombstone (
  singleton        INTEGER PRIMARY KEY CHECK (singleton = 1),
  apple_sub_sha256 TEXT NOT NULL,
  deleted_at       INTEGER NOT NULL
);
