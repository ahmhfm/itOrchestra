-- Phase 0.12 - MSSQL application-consistent backup, kept INSIDE the database as a stored
-- procedure (the platform rule: no SQL in the app/CI layer; the Velero hook only EXECs this SP).
--
-- It writes a COPY_ONLY, checksummed, compressed backup of every ONLINE user database to a fixed
-- filename on the data PVC (/var/opt/mssql/backups/<db>.bak, INIT = overwrite the previous one).
-- Velero's File System Backup then captures those .bak files and versions them per daily backup
-- in MinIO, so the volume only ever holds the latest copy (no unbounded growth on the PVC).
--
-- COPY_ONLY is used so the backup never disturbs the differential/log chain of the Availability
-- Group, and so it is also valid if ever run against a readable secondary.
USE [master];
GO

CREATE OR ALTER PROCEDURE dbo.sp_Maint_Backup_AllDatabases
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @dir   nvarchar(260) = N'/var/opt/mssql/backups';
    DECLARE @name  sysname;
    DECLARE @path  nvarchar(520);
    DECLARE @sql   nvarchar(max);

    -- Ensure the target directory exists (BACKUP will not create it).
    EXEC master.dbo.xp_create_subdir @dir;

    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name
        FROM sys.databases
        WHERE database_id > 4              -- skip master/tempdb/model/msdb
          AND state = 0                    -- ONLINE only
          AND source_database_id IS NULL   -- skip database snapshots
          AND is_read_only = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @name;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @path = @dir + N'/' + @name + N'.bak';
        SET @sql  = N'BACKUP DATABASE ' + QUOTENAME(@name) +
                    N' TO DISK = N''' + REPLACE(@path, N'''', N'''''') + N'''' +
                    N' WITH COPY_ONLY, INIT, FORMAT, CHECKSUM, COMPRESSION;';

        BEGIN TRY
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            -- Log and continue with the next database rather than aborting the whole run.
            PRINT CONCAT(N'sp_Maint_Backup_AllDatabases: failed for [', @name, N']: ',
                         ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @name;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END
GO
