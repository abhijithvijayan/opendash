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
  proof    TEXT,                      -- SHA-256 of the ping's proof of work, taken once
  via      TEXT    NOT NULL DEFAULT '', -- which deployment took it: legacy, v2; '' before
  -- The head unit (0.3.5 on), '' before: the same on every unit of a model and firmware.
  screen   TEXT    NOT NULL DEFAULT '', -- 1280x768
  density  TEXT    NOT NULL DEFAULT '', -- in use (wm density)
  density_default TEXT NOT NULL DEFAULT '', -- the one it ships with
  maker    TEXT    NOT NULL DEFAULT '',
  device   TEXT    NOT NULL DEFAULT '', -- the head unit's model, not the scooter's
  board    TEXT    NOT NULL DEFAULT '',
  soc      TEXT    NOT NULL DEFAULT '',
  abi      TEXT    NOT NULL DEFAULT '',
  ram_gb   TEXT    NOT NULL DEFAULT '', -- rounded
  fw       TEXT    NOT NULL DEFAULT '', -- firmware build
  patch    TEXT    NOT NULL DEFAULT ''  -- Android security patch
);
CREATE UNIQUE INDEX IF NOT EXISTS pings_proof ON pings (proof);
CREATE INDEX IF NOT EXISTS pings_week ON pings (week);
