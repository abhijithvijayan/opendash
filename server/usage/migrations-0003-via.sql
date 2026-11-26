-- Which deployment took each ping. The address built into the app changed
-- (0.3.4) after forks had copied the old one: the old Worker runs on as
-- "legacy" for installs not yet updated, the new one is "v2".
-- Run once on the live database, before deploying the Worker:
--   npx wrangler d1 execute opendash-usage --remote --file migrations-0003-via.sql
ALTER TABLE pings ADD COLUMN via TEXT NOT NULL DEFAULT '';
