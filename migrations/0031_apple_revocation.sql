-- Sign in with Apple server-side grant lifecycle.
--
-- Apple refresh tokens are credentials, kept outside the broad users row so
-- ordinary account reads and exports cannot expose them accidentally. One
-- credential belongs to exactly one app principal and is replaced only after
-- a newly supplied authorization code has been exchanged and subject-bound.
CREATE TABLE apple_refresh_tokens (
  user_id       TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  refresh_token TEXT NOT NULL,
  updated_at    INTEGER NOT NULL
);

-- A Sign in with Apple code exchange crosses D1 -> Apple's network -> D1.
-- Reserve that gap before the request leaves D1 so account deletion cannot
-- falsely report `revoked` while a newly issued grant is still untracked.
--
-- `revocation_uncertain` is intentionally sticky: a timed-out exchange may
-- have issued an unknown grant, and a later successful exchange cannot prove
-- that older grant absent. A fresh active reservation blocks deletion. Stale
-- active work (>60s) is treated as uncertain so a crashed sign-in cannot
-- strand deletion forever.
CREATE TABLE apple_grant_exchange_state (
  user_id                TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  reservation_id         TEXT,
  active_since           INTEGER,
  revocation_uncertain   INTEGER NOT NULL DEFAULT 0
    CHECK (revocation_uncertain IN (0, 1)),
  CHECK (
    (reservation_id IS NULL AND active_since IS NULL) OR
    (reservation_id IS NOT NULL AND active_since IS NOT NULL)
  )
);

-- Deletion is a multi-system operation: claim a durable, key-bound intent
-- under D1's write lock before talking to Apple. While this row exists, normal
-- feature auth and credential replacement are closed. `apple_revocation` is
-- filled before the local deletion transaction so a crash-safe retry can
-- continue without changing an already-known provider outcome.
CREATE TABLE account_deletion_intents (
  user_id                TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  idempotency_key_sha256 TEXT NOT NULL,
  apple_revocation       TEXT CHECK (
    apple_revocation IS NULL OR
    apple_revocation IN ('revoked', 'manual_required')
  ),
  created_at             INTEGER NOT NULL
);

-- Old receipts predate provider revocation and truthfully require the manual
-- Apple Account handoff. New receipts persist the outcome returned to iOS.
ALTER TABLE account_deletion_receipts
  ADD COLUMN apple_revocation TEXT NOT NULL DEFAULT 'manual_required'
  CHECK (apple_revocation IN ('revoked', 'manual_required'));

-- Defense in depth for stale auth-code exchanges. The service upsert is
-- conditional too, but these triggers stop a future direct insert/update from
-- replacing a credential after deletion has been claimed or committed.
CREATE TRIGGER reject_deleting_apple_refresh_token_insert
BEFORE INSERT ON apple_refresh_tokens
WHEN NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id)
  OR EXISTS (
       SELECT 1 FROM account_deletion_intents WHERE user_id = NEW.user_id
     )
  OR EXISTS (
       SELECT 1 FROM account_deletion_receipts WHERE user_id = NEW.user_id
     )
BEGIN
  SELECT RAISE(ABORT, 'deleting_user');
END;

CREATE TRIGGER reject_deleting_apple_refresh_token_update
BEFORE UPDATE ON apple_refresh_tokens
WHEN EXISTS (
       SELECT 1 FROM account_deletion_intents WHERE user_id = OLD.user_id
     )
  OR EXISTS (
       SELECT 1 FROM account_deletion_receipts WHERE user_id = OLD.user_id
     )
BEGIN
  SELECT RAISE(ABORT, 'deleting_user');
END;

-- OAuth requests authenticated immediately before intent creation must not
-- mint a new MCP credential during the provider-I/O window.
CREATE TRIGGER reject_deleting_oauth_code
BEFORE INSERT ON oauth_codes
WHEN NEW.user_id IS NOT NULL
 AND EXISTS (
       SELECT 1 FROM account_deletion_intents WHERE user_id = NEW.user_id
     )
BEGIN
  SELECT RAISE(ABORT, 'deleting_user');
END;

CREATE TRIGGER reject_deleting_oauth_token
BEFORE INSERT ON oauth_tokens
WHEN NEW.user_id IS NOT NULL
 AND EXISTS (
       SELECT 1 FROM account_deletion_intents WHERE user_id = NEW.user_id
     )
BEGIN
  SELECT RAISE(ABORT, 'deleting_user');
END;

-- An invite request can pass app-JWT middleware immediately before deletion
-- claims its intent. Do not let that already-authenticated request consume a
-- shared invite while the users row intentionally remains for provider I/O.
-- Deletion cleanup only clears `used_by` on an already-used invite, so it does
-- not match this unused -> used transition.
CREATE TRIGGER reject_deleting_invite_redemption
BEFORE UPDATE OF used_at, used_by ON group_invites
WHEN OLD.used_at IS NULL
 AND NEW.used_at IS NOT NULL
 AND NEW.used_by IS NOT NULL
 AND (
   NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.used_by)
   OR EXISTS (
     SELECT 1 FROM account_deletion_intents WHERE user_id = NEW.used_by
   )
   OR EXISTS (
     SELECT 1 FROM account_deletion_receipts WHERE user_id = NEW.used_by
   )
 )
BEGIN
  SELECT RAISE(ABORT, 'deleting_user');
END;
