-- itOrchestra - Phase 0.10. CrewAI audit database bootstrap (runs on the 0.7 AG PRIMARY, master).
-- Creates the per-service database 'CrewAiDb', adds it to the Availability Group (so it
-- replicates), and creates a least-privilege SQL login used only by the CrewAI service.
-- Idempotent: guarded with IF NOT EXISTS. The app password is passed as the sqlcmd variable
-- $(AppPassword) (from a Kubernetes Secret) - never hardcoded.
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- Least-privilege login for the CrewAI service (DB user + EXEC granted in 02-schema.sql).
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'crewai_app')
    CREATE LOGIN [crewai_app] WITH PASSWORD = N'$(AppPassword)', CHECK_POLICY = ON;
GO

-- Create the database and put it in FULL recovery (required to join an AG).
IF DB_ID(N'CrewAiDb') IS NULL
BEGIN
    CREATE DATABASE [CrewAiDb];
    ALTER DATABASE [CrewAiDb] SET RECOVERY FULL;
END
GO

-- Add to the Availability Group 'ag1' (automatic seeding to the secondary). Best-effort:
-- the database is fully usable on the primary even if AG membership is deferred.
IF EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = N'ag1')
   AND (SELECT group_database_id FROM sys.databases WHERE name = N'CrewAiDb') IS NULL
BEGIN
    BEGIN TRY
        BACKUP DATABASE [CrewAiDb] TO DISK = N'/var/opt/mssql/data/CrewAiDb_seed.bak' WITH FORMAT, INIT;
        ALTER AVAILABILITY GROUP [ag1] ADD DATABASE [CrewAiDb];
    END TRY
    BEGIN CATCH
        PRINT 'WARN: could not add CrewAiDb to AG ag1: ' + ERROR_MESSAGE();
    END CATCH
END
GO
