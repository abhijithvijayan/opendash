-- The head unit's hardware and firmware, sent from OpenDash 0.3.5 on.
-- Run once on the live database, before deploying the Worker:
--   npx wrangler d1 execute opendash-usage --remote --file migrations-0004-hardware.sql
ALTER TABLE pings ADD COLUMN screen TEXT NOT NULL DEFAULT '';
ALTER TABLE pings ADD COLUMN density TEXT NOT NULL DEFAULT '';
ALTER TABLE pings ADD COLUMN density_default TEXT NOT NULL DEFAULT '';
ALTER TABLE pings ADD COLUMN maker TEXT NOT NULL DEFAULT '';
ALTER TABLE pings ADD COLUMN device TEXT NOT NULL DEFAULT '';
ALTER TABLE pings ADD COLUMN board TEXT NOT NULL DEFAULT '';
ALTER TABLE pings ADD COLUMN soc TEXT NOT NULL DEFAULT '';
ALTER TABLE pings ADD COLUMN abi TEXT NOT NULL DEFAULT '';
ALTER TABLE pings ADD COLUMN ram_gb TEXT NOT NULL DEFAULT '';
ALTER TABLE pings ADD COLUMN fw TEXT NOT NULL DEFAULT '';
ALTER TABLE pings ADD COLUMN patch TEXT NOT NULL DEFAULT '';
