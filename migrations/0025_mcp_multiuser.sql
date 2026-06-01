-- M3: multi-tenant MCP. Bind OAuth codes/tokens to a user_id, and let
-- non-owner users authenticate the /oauth/authorize step with a personal
-- passphrase (PBKDF2-SHA256, per-user salt). The owner keeps the
-- OWNER_AUTH_PASSPHRASE env path.
--
-- Back-compat: existing oauth_tokens have user_id NULL → validateBearer
-- resolves them to the owner, so already-connected claude.ai sessions keep
-- working as the owner without re-auth.
ALTER TABLE oauth_codes ADD COLUMN user_id TEXT;
ALTER TABLE oauth_tokens ADD COLUMN user_id TEXT;

-- Per-user MCP passphrase. NULL → no passphrase set (that user cannot open a
-- Claude MCP session via OAuth). Set via POST /api/me/mcp-passphrase.
ALTER TABLE users ADD COLUMN mcp_passphrase_hash TEXT;
ALTER TABLE users ADD COLUMN mcp_passphrase_salt TEXT;
