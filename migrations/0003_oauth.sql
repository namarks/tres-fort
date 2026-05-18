-- OAuth 2.1 storage for claude.ai/desktop custom-connector auth.
-- Single user: /authorize is gated by OWNER_AUTH_PASSPHRASE. DCR (/register)
-- is open per spec but grants nothing without passing the consent gate.

CREATE TABLE oauth_clients (
  client_id      TEXT PRIMARY KEY,
  client_secret  TEXT,                 -- NULL for public (PKCE) clients
  redirect_uris  TEXT NOT NULL,        -- JSON array
  client_name    TEXT,
  created_at     INTEGER NOT NULL
);

CREATE TABLE oauth_codes (
  code                  TEXT PRIMARY KEY,
  client_id             TEXT NOT NULL,
  redirect_uri          TEXT NOT NULL,
  code_challenge        TEXT NOT NULL,
  code_challenge_method TEXT NOT NULL,
  scope                 TEXT,
  resource              TEXT,
  expires_at            INTEGER NOT NULL,
  created_at            INTEGER NOT NULL
);

CREATE TABLE oauth_tokens (
  access_token  TEXT PRIMARY KEY,
  refresh_token TEXT UNIQUE,
  client_id     TEXT NOT NULL,
  scope         TEXT,
  expires_at    INTEGER NOT NULL,
  created_at    INTEGER NOT NULL
);

CREATE INDEX ix_oauth_tokens_refresh ON oauth_tokens(refresh_token);
