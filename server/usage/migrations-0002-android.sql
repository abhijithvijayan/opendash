-- Adds the head unit's Android release to an existing pings table.
-- Run once on the live database, before or after deploying the Worker:
--   npx wrangler d1 execute opendash-usage --remote --file migrations-0002-android.sql
ALTER TABLE pings ADD COLUMN android TEXT NOT NULL DEFAULT '';
