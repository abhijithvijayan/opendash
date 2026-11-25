-- One row per ping. No identifier of any kind, and no IP address: a row
-- says "one OpenDash ran in this week with these versions", nothing more.
CREATE TABLE IF NOT EXISTS pings (
  week     TEXT    NOT NULL,          -- ISO week, e.g. 2026-W48
  new      INTEGER NOT NULL,          -- 1 on the first ping after an install
  app      TEXT    NOT NULL,          -- OpenDash version
  build    INTEGER NOT NULL,          -- OpenDash build number (0 unknown)
  gen      TEXT    NOT NULL,          -- scooter generation, '' unknown
  model    TEXT    NOT NULL,          -- scooter model, '' unknown
  moveos   TEXT    NOT NULL,          -- MoveOS version, '' unknown
  stock    TEXT    NOT NULL,          -- stock vehicle service version, '' unknown
  android  TEXT    NOT NULL DEFAULT '', -- head unit's Android release, '' unknown
  country  TEXT    NOT NULL,          -- two letters from Cloudflare, '' unknown
  at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  proof    TEXT                       -- SHA-256 of the ping's proof of work, taken once
);
CREATE UNIQUE INDEX IF NOT EXISTS pings_proof ON pings (proof);
CREATE INDEX IF NOT EXISTS pings_week ON pings (week);
