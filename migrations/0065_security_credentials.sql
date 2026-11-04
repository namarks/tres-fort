-- Security remediation. Credential-storage enforcement is activated only by
-- the explicit backfill procedure; applying this schema does not discard data.
CREATE TABLE app_session_revocations (
  session_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
CREATE INDEX ix_app_session_revocations_expiry ON app_session_revocations(expires_at);

CREATE TABLE coach_connect_codes (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  code_sha256 TEXT NOT NULL UNIQUE,
  expires_at INTEGER NOT NULL
);
CREATE TABLE auth_rate_limits (
  bucket TEXT PRIMARY KEY,
  window_start INTEGER NOT NULL,
  attempts INTEGER NOT NULL
);
CREATE INDEX ix_auth_rate_limits_window ON auth_rate_limits(window_start);

ALTER TABLE intervals_oauth_states ADD COLUMN app_session_id TEXT;
CREATE TABLE intervals_oauth_completions (
  completion_sha256 TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  app_session_id TEXT NOT NULL,
  credential_generation INTEGER NOT NULL,
  credential_ciphertext TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX ix_intervals_oauth_completions_expiry ON intervals_oauth_completions(expires_at);

CREATE TABLE credential_storage_policy (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  enforced INTEGER NOT NULL DEFAULT 0 CHECK (enforced IN (0, 1))
);
INSERT INTO credential_storage_policy(id, enforced) VALUES (1, 0);

-- Version-marked digests distinguish stored hashes from raw bearer values.
-- During the documented rolling transition only legacy readers need raw rows.
CREATE TRIGGER encrypted_intervals_credentials_insert BEFORE INSERT ON users
WHEN (SELECT enforced FROM credential_storage_policy WHERE id=1)=1
 AND ((NEW.intervals_api_key IS NOT NULL AND NEW.intervals_api_key NOT LIKE 'sealed:v1:%')
   OR (NEW.intervals_oauth_access_token IS NOT NULL AND NEW.intervals_oauth_access_token NOT LIKE 'sealed:v1:%')
   OR (NEW.intervals_oauth_refresh_token IS NOT NULL AND NEW.intervals_oauth_refresh_token NOT LIKE 'sealed:v1:%'))
BEGIN SELECT RAISE(ABORT, 'plaintext_provider_credential'); END;
CREATE TRIGGER encrypted_intervals_credentials_update BEFORE UPDATE OF intervals_api_key,intervals_oauth_access_token,intervals_oauth_refresh_token ON users
WHEN (SELECT enforced FROM credential_storage_policy WHERE id=1)=1
 AND ((NEW.intervals_api_key IS NOT NULL AND NEW.intervals_api_key NOT LIKE 'sealed:v1:%')
   OR (NEW.intervals_oauth_access_token IS NOT NULL AND NEW.intervals_oauth_access_token NOT LIKE 'sealed:v1:%')
   OR (NEW.intervals_oauth_refresh_token IS NOT NULL AND NEW.intervals_oauth_refresh_token NOT LIKE 'sealed:v1:%'))
BEGIN SELECT RAISE(ABORT, 'plaintext_provider_credential'); END;
CREATE TRIGGER hashed_oauth_credentials_insert BEFORE INSERT ON oauth_tokens
WHEN (SELECT enforced FROM credential_storage_policy WHERE id=1)=1
 AND (NEW.access_token NOT GLOB 'sha256:*' OR NEW.refresh_token NOT GLOB 'sha256:*')
BEGIN SELECT RAISE(ABORT, 'plaintext_coach_credential'); END;
CREATE TRIGGER hashed_oauth_credentials_update BEFORE UPDATE OF access_token,refresh_token ON oauth_tokens
WHEN (SELECT enforced FROM credential_storage_policy WHERE id=1)=1
 AND (NEW.access_token NOT GLOB 'sha256:*' OR NEW.refresh_token NOT GLOB 'sha256:*')
BEGIN SELECT RAISE(ABORT, 'plaintext_coach_credential'); END;
CREATE TRIGGER credential_storage_enforcement_guard BEFORE UPDATE OF enforced ON credential_storage_policy
WHEN NEW.enforced < OLD.enforced OR (NEW.enforced=1 AND (
 EXISTS (SELECT 1 FROM users WHERE
   (intervals_api_key IS NOT NULL AND intervals_api_key NOT LIKE 'sealed:v1:%') OR
   (intervals_oauth_access_token IS NOT NULL AND intervals_oauth_access_token NOT LIKE 'sealed:v1:%') OR
   (intervals_oauth_refresh_token IS NOT NULL AND intervals_oauth_refresh_token NOT LIKE 'sealed:v1:%'))
 OR EXISTS (SELECT 1 FROM oauth_tokens WHERE access_token NOT GLOB 'sha256:*' OR refresh_token NOT GLOB 'sha256:*')
))
BEGIN SELECT RAISE(ABORT, 'credential_storage_not_ready'); END;
