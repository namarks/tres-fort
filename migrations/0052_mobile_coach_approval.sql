-- Unauthenticated, short-lived OAuth navigation. No account or token is
-- associated until an authenticated member explicitly approves in iOS.
CREATE TABLE oauth_mobile_requests (
  id TEXT PRIMARY KEY,
  client_id TEXT NOT NULL REFERENCES oauth_clients(client_id) ON DELETE CASCADE,
  redirect_uri TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  state TEXT NOT NULL,
  resource TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX ix_oauth_mobile_requests_expiry ON oauth_mobile_requests(expires_at);
