-- M2: Groups + invite-gated sign-in.
--
-- The single-user invariant (one Apple sub, one user row) becomes a
-- multi-user-with-invite-gating one. Random Apple sign-ins are still
-- rejected — a new sub must either be the bootstrap owner (OWNER_APPLE_SUB
-- or the empty-users-table fresh-install case) OR present a valid invite
-- code that adds them to a group.
--
-- Three tables:
--   * groups            — friend/family containers (creator auto-joins).
--   * group_members     — composite PK (group_id, user_id); per-group
--                         nickname override via display_name (NULL = use
--                         users.display_name).
--   * group_invites     — short shareable codes (6 chars from a 32-char
--                         no-ambiguous alphabet). Single-use: redeemed
--                         rows have used_at + used_by set; default
--                         expires_at = created_at + 30 days (caller may
--                         override to NULL = never).
--
-- Idempotent on re-apply (CREATE TABLE/INDEX IF NOT EXISTS), matching the
-- pattern used by 0006/0008/0015/0017 — the vitest D1 path re-applies
-- migrations per suite and must be a safe no-op.
--
-- Not bumping plans.version on any group write: groups live OUTSIDE the
-- versioned plan-tree document (different consistency class — closer to
-- the append-only log + audit_log trail than the plan tree).

CREATE TABLE IF NOT EXISTS groups (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  created_by  TEXT NOT NULL REFERENCES users(id),
  created_at  INTEGER NOT NULL              -- epoch ms
);

CREATE TABLE IF NOT EXISTS group_members (
  group_id      TEXT NOT NULL REFERENCES groups(id),
  user_id       TEXT NOT NULL REFERENCES users(id),
  display_name  TEXT,                       -- per-group nickname override (NULL = use users.display_name)
  joined_at     INTEGER NOT NULL,
  PRIMARY KEY (group_id, user_id)
);
CREATE INDEX IF NOT EXISTS ix_group_members_user ON group_members(user_id);

CREATE TABLE IF NOT EXISTS group_invites (
  code        TEXT PRIMARY KEY,             -- short shareable (6 chars from no-ambiguous 32-alphabet)
  group_id    TEXT NOT NULL REFERENCES groups(id),
  created_by  TEXT NOT NULL REFERENCES users(id),
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER,                      -- NULL = never expires; default 30 days from create
  used_at     INTEGER,                      -- NULL = unused
  used_by     TEXT REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS ix_invites_group ON group_invites(group_id);
