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
-- recovery is an intentional D1 operation that removes this row AND either
-- configures an explicit replacement OWNER_APPLE_SUB or deliberately inserts
-- a new bootstrap sentinel. The durable receipt below prevents tombstone
-- removal alone from promoting the earliest surviving member.

CREATE TABLE IF NOT EXISTS owner_deletion_tombstone (
  singleton        INTEGER PRIMARY KEY CHECK (singleton = 1),
  apple_sub_sha256 TEXT NOT NULL,
  deleted_at       INTEGER NOT NULL
);

-- One durable receipt per deleted principal serves two purposes:
--
-- 1. DELETE /api/me can acknowledge a retry after the users row and its JWT
--    principal have already been removed. Only the original high-entropy
--    idempotency key (stored as a digest) receives that acknowledgement.
-- 2. INSERT triggers below make the deletion marker participate in the same
--    SQLite write lock as late in-flight writes. A write that lands first is
--    removed by the deletion batch; a write that lands second is rejected.
CREATE TABLE IF NOT EXISTS account_deletion_receipts (
  user_id                TEXT PRIMARY KEY,
  idempotency_key_sha256 TEXT NOT NULL,
  owner_tombstoned       INTEGER NOT NULL CHECK (owner_tombstoned IN (0, 1)),
  deleted_at             INTEGER NOT NULL
);

-- These tables intentionally predate or omit users foreign keys. Prevent an
-- authenticated request, intervals callback, or OAuth exchange that began
-- before deletion from recreating caller-owned rows after the transaction.
CREATE TRIGGER IF NOT EXISTS reject_deleted_external_event
BEFORE INSERT ON external_events
WHEN NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id)
  OR EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = NEW.user_id)
BEGIN
  SELECT RAISE(ABORT, 'deleted_user');
END;

CREATE TRIGGER IF NOT EXISTS reject_deleted_external_activity
BEFORE INSERT ON external_activities
WHEN NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id)
  OR EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = NEW.user_id)
BEGIN
  SELECT RAISE(ABORT, 'deleted_user');
END;

CREATE TRIGGER IF NOT EXISTS reject_deleted_audit_log
BEFORE INSERT ON audit_log
WHEN NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id)
  OR EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = NEW.user_id)
BEGIN
  SELECT RAISE(ABORT, 'deleted_user');
END;

CREATE TRIGGER IF NOT EXISTS reject_deleted_intervals_oauth_state
BEFORE INSERT ON intervals_oauth_states
WHEN NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id)
  OR EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = NEW.user_id)
BEGIN
  SELECT RAISE(ABORT, 'deleted_user');
END;

CREATE TRIGGER IF NOT EXISTS reject_deleted_oauth_code
BEFORE INSERT ON oauth_codes
WHEN NEW.user_id IS NOT NULL
 AND (
   NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id)
   OR EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = NEW.user_id)
 )
BEGIN
  SELECT RAISE(ABORT, 'deleted_user');
END;

CREATE TRIGGER IF NOT EXISTS reject_deleted_oauth_token
BEFORE INSERT ON oauth_tokens
WHEN NEW.user_id IS NOT NULL
 AND (
   NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id)
   OR EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = NEW.user_id)
 )
BEGIN
  SELECT RAISE(ABORT, 'deleted_user');
END;
