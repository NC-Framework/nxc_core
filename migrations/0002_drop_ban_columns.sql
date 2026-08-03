-- nxc_core — remove the ban columns.
--
-- Nexus Core does not implement banning. FXServer and txAdmin do, with
-- durations, identifier matching, an admin interface, and an appeal trail, and
-- they match on platform identifiers rather than on anything stored here.
--
-- The columns are removed rather than left unused. A column nothing writes and
-- nothing reads is a trap: the next person to see `banned_until` will reasonably
-- assume it is authoritative, and act on a value that is always NULL.
--
-- Reversible: yes, by re-adding three objects, which the down notes below
-- describe. Destructive: TECHNICALLY YES — it drops columns. In practice no data
-- is lost, because nothing has ever written to them; the framework never
-- implemented the feature they were for.
--
-- Expected duration: instant. An ALTER on a table with a handful of rows.

-- MariaDB supports IF EXISTS on DROP COLUMN and DROP INDEX, which is what makes
-- this migration idempotent — and idempotency is the only recovery path a DDL
-- migration has, because MySQL implicitly commits around every statement.
ALTER TABLE `nxc_core_accounts` DROP INDEX IF EXISTS `idx_banned_until`;

ALTER TABLE `nxc_core_accounts` DROP COLUMN IF EXISTS `banned_until`;

ALTER TABLE `nxc_core_accounts` DROP COLUMN IF EXISTS `ban_reason`;

-- To reverse:
--   ALTER TABLE `nxc_core_accounts`
--       ADD COLUMN `banned_until` DATETIME(3)  NULL,
--       ADD COLUMN `ban_reason`   VARCHAR(512) NULL,
--       ADD KEY `idx_banned_until` (`banned_until`);
