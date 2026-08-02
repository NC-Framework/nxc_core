-- nxc_core — accounts, characters, identifier mappings, and capability grants.
--
-- Every table here belongs to nxc_core. No other resource writes them, and
-- nxc_core writes no other resource's tables.
--
-- Reversible: yes, by dropping these four tables. Destructive: no — it creates
-- only. Expected duration: instant on any realistic size.

-- ---------------------------------------------------------------- accounts
-- An account represents a real person. Bans, priority, and framework
-- permissions hang off the account, because a ban that only stops one character
-- is not a ban.
CREATE TABLE IF NOT EXISTS `nxc_core_accounts` (
    `id`              VARCHAR(32)  NOT NULL,
    `display_name`    VARCHAR(64)      NULL,
    `whitelisted`     TINYINT(1)   NOT NULL DEFAULT 0,
    `priority`        INT          NOT NULL DEFAULT 0,
    `character_slots` INT          NOT NULL DEFAULT 5,
    `banned_until`    DATETIME(3)      NULL,
    `ban_reason`      VARCHAR(512)     NULL,
    `created_at`      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`      DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                                       ON UPDATE CURRENT_TIMESTAMP(3),
    `last_seen_at`    DATETIME(3)      NULL,
    PRIMARY KEY (`id`),
    -- The ban check runs on every connection, so it is indexed.
    KEY `idx_banned_until` (`banned_until`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;

-- ------------------------------------------------------- account identifiers
-- A player presents several platform identifiers. These map TO an account; they
-- are not the account identifier. An IP address is never an identity key and is
-- deliberately absent.
CREATE TABLE IF NOT EXISTS `nxc_core_account_identifiers` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `account_id`  VARCHAR(32)     NOT NULL,
    `kind`        VARCHAR(16)     NOT NULL,
    `value`       VARCHAR(128)    NOT NULL,
    `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`id`),
    -- One identifier maps to exactly one account. The constraint is what makes
    -- that true, rather than an application check with a race in it.
    UNIQUE KEY `uq_kind_value` (`kind`, `value`),
    KEY `idx_account` (`account_id`),
    CONSTRAINT `fk_identifier_account`
        FOREIGN KEY (`account_id`) REFERENCES `nxc_core_accounts` (`id`)
        ON DELETE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;

-- --------------------------------------------------------------- characters
-- An account holds multiple characters. Nearly all gameplay state hangs off a
-- character rather than an account.
--
-- Note what is NOT here: no cash, no bank, no inventory, no job. Those belong to
-- nxc_banking, nxc_inventory, and nxc_jobs, and putting them on the character
-- row is how a framework acquires a domain it does not own.
CREATE TABLE IF NOT EXISTS `nxc_core_characters` (
    `id`             VARCHAR(32) NOT NULL,
    `account_id`     VARCHAR(32) NOT NULL,
    `first_name`     VARCHAR(48) NOT NULL,
    `last_name`      VARCHAR(48) NOT NULL,
    `date_of_birth`  DATE            NULL,
    `biography`      TEXT            NULL,
    `position_x`     DOUBLE          NULL,
    `position_y`     DOUBLE          NULL,
    `position_z`     DOUBLE          NULL,
    `heading`        FLOAT           NULL,
    `routing_bucket` INT         NOT NULL DEFAULT 0,
    `created_at`     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                                      ON UPDATE CURRENT_TIMESTAMP(3),
    `last_played_at` DATETIME(3)     NULL,
    -- Soft delete: a character is recoverable within a documented window, and
    -- deletion is audited.
    `deleted_at`     DATETIME(3)     NULL,
    PRIMARY KEY (`id`),
    KEY `idx_account_active` (`account_id`, `deleted_at`),
    KEY `idx_last_played` (`last_played_at`),
    CONSTRAINT `fk_character_account`
        FOREIGN KEY (`account_id`) REFERENCES `nxc_core_accounts` (`id`)
        ON DELETE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;

-- -------------------------------------------------------- capability grants
-- A character may hold multiple concurrent employments, each granting or denying
-- capabilities. Resolution unions grants and lets denials win, so a temporary
-- contract cannot restore a capability a department deliberately revoked.
--
-- Grants are stored rather than held in a session, so revocation reaches a
-- player who is offline.
CREATE TABLE IF NOT EXISTS `nxc_core_capability_grants` (
    `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `character_id` VARCHAR(32)     NOT NULL,
    `source`       VARCHAR(24)     NOT NULL,
    `source_id`    VARCHAR(64)         NULL,
    `capability`   VARCHAR(96)     NOT NULL,
    `effect`       VARCHAR(8)      NOT NULL DEFAULT 'allow',
    `granted_by`   VARCHAR(32)         NULL,
    `created_at`   DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `expires_at`   DATETIME(3)         NULL,
    PRIMARY KEY (`id`),
    -- One row per character, source, and capability. Re-granting updates rather
    -- than duplicating.
    UNIQUE KEY `uq_grant` (`character_id`, `source`, `source_id`, `capability`),
    -- Resolution reads every grant for a character on load, so this is the
    -- index that matters.
    KEY `idx_character` (`character_id`),
    KEY `idx_source` (`source`, `source_id`),
    KEY `idx_expires` (`expires_at`),
    CONSTRAINT `fk_grant_character`
        FOREIGN KEY (`character_id`) REFERENCES `nxc_core_characters` (`id`)
        ON DELETE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;
