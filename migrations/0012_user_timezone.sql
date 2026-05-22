-- Owner timezone for correct "today" semantics on the MCP read side.
--
-- The iOS app owns the device-local civil date (it sends sessions.date as a
-- YYYY-MM-DD string). But MCP reads (get_today_workout, log_set default
-- date, the coach brief) ran off `new Date().toISOString()` = UTC, so after
-- ~17:00 PT "today" rolled to tomorrow. Storing the device's IANA timezone
-- lets the server compute today in the user's actual zone — and because the
-- app re-reports it on every sync, it follows the user across time zones.
-- Nullable: falls back to UTC (the prior behavior) until the first sync.
ALTER TABLE users ADD COLUMN timezone TEXT;
