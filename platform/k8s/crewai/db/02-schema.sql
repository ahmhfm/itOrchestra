-- itOrchestra - Phase 0.10. CrewAI audit schema (runs in CrewAiDb on the AG primary).
-- ALL data access for the service goes through these stored procedures (the Python app only
-- EXECs them - no inline SQL in app code). Idempotent: tables guarded with IF NOT EXISTS,
-- procedures use CREATE OR ALTER. The crewai_app user is granted EXEC only (no table rights),
-- which enforces the "stored-procedures-only" contract at the database level.
SET NOCOUNT ON;
GO

-- ---------- Tables (the audit trail of every AI decision) ----------
IF OBJECT_ID(N'dbo.AiDecision', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AiDecision (
        DecisionId        UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_AiDecision PRIMARY KEY,
        AgentKind         NVARCHAR(32)     NOT NULL,
        Status            NVARCHAR(32)     NOT NULL,
        Action            NVARCHAR(128)    NOT NULL,
        Target            NVARCHAR(256)    NULL,
        RequiresApproval  BIT              NOT NULL CONSTRAINT DF_AiDecision_RA DEFAULT(0),
        Rationale         NVARCHAR(MAX)    NULL,
        RequestedBy       NVARCHAR(256)    NULL,
        CorrelationId     NVARCHAR(64)     NULL,
        IdempotencyKey    NVARCHAR(128)    NULL,
        CreatedAt         DATETIME2(3)     NOT NULL CONSTRAINT DF_AiDecision_CA DEFAULT(SYSUTCDATETIME()),
        UpdatedAt         DATETIME2(3)     NOT NULL CONSTRAINT DF_AiDecision_UA DEFAULT(SYSUTCDATETIME())
    );
    CREATE UNIQUE INDEX UX_AiDecision_Idem ON dbo.AiDecision(IdempotencyKey) WHERE IdempotencyKey IS NOT NULL;
    CREATE INDEX IX_AiDecision_Agent_Created ON dbo.AiDecision(AgentKind, CreatedAt DESC);
END
GO

IF OBJECT_ID(N'dbo.AiDecisionSource', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AiDecisionSource (
        Id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AiDecisionSource PRIMARY KEY,
        DecisionId  UNIQUEIDENTIFIER NOT NULL,
        Collection  NVARCHAR(64)     NOT NULL,
        PointId     NVARCHAR(128)    NULL,
        Score       FLOAT            NULL,
        Snippet     NVARCHAR(MAX)    NULL,
        CONSTRAINT FK_AiDecisionSource_Decision FOREIGN KEY (DecisionId)
            REFERENCES dbo.AiDecision(DecisionId) ON DELETE CASCADE
    );
    CREATE INDEX IX_AiDecisionSource_Decision ON dbo.AiDecisionSource(DecisionId);
END
GO

IF OBJECT_ID(N'dbo.AiApproval', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AiApproval (
        DecisionId      UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_AiApproval PRIMARY KEY,
        ApprovalStatus  NVARCHAR(16)     NOT NULL CONSTRAINT DF_AiApproval_St DEFAULT(N'PENDING'),
        Approver        NVARCHAR(256)    NULL,
        Reason          NVARCHAR(MAX)    NULL,
        CreatedAt       DATETIME2(3)     NOT NULL CONSTRAINT DF_AiApproval_CA DEFAULT(SYSUTCDATETIME()),
        DecidedAt       DATETIME2(3)     NULL,
        CONSTRAINT FK_AiApproval_Decision FOREIGN KEY (DecisionId)
            REFERENCES dbo.AiDecision(DecisionId) ON DELETE CASCADE
    );
    CREATE INDEX IX_AiApproval_Status ON dbo.AiApproval(ApprovalStatus, CreatedAt DESC);
END
GO

-- ---------- Stored procedures (sp_Module_Action_Entity) ----------

-- Insert a decision (idempotent on IdempotencyKey). If RequiresApproval, also opens a PENDING
-- approval row. Returns the effective DecisionId + Status as a single-row result set.
CREATE OR ALTER PROCEDURE dbo.sp_CrewAi_Audit_InsertDecision
    @DecisionId       UNIQUEIDENTIFIER,
    @AgentKind        NVARCHAR(32),
    @Status           NVARCHAR(32),
    @Action           NVARCHAR(128),
    @Target           NVARCHAR(256) = NULL,
    @RequiresApproval BIT,
    @Rationale        NVARCHAR(MAX) = NULL,
    @RequestedBy      NVARCHAR(256) = NULL,
    @CorrelationId    NVARCHAR(64)  = NULL,
    @IdempotencyKey   NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Idempotent replay: return the prior decision instead of inserting a duplicate.
    IF @IdempotencyKey IS NOT NULL
    BEGIN
        DECLARE @ExistingId UNIQUEIDENTIFIER, @ExistingStatus NVARCHAR(32);
        SELECT @ExistingId = DecisionId, @ExistingStatus = Status
          FROM dbo.AiDecision WHERE IdempotencyKey = @IdempotencyKey;
        IF @ExistingId IS NOT NULL
        BEGIN
            SELECT CAST(@ExistingId AS NVARCHAR(36)) AS DecisionId, @ExistingStatus AS Status, CAST(1 AS BIT) AS Replayed;
            RETURN;
        END
    END

    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO dbo.AiDecision
            (DecisionId, AgentKind, Status, Action, Target, RequiresApproval,
             Rationale, RequestedBy, CorrelationId, IdempotencyKey)
        VALUES
            (@DecisionId, @AgentKind, @Status, @Action, @Target, @RequiresApproval,
             @Rationale, @RequestedBy, @CorrelationId, @IdempotencyKey);

        IF @RequiresApproval = 1
            INSERT INTO dbo.AiApproval (DecisionId, ApprovalStatus) VALUES (@DecisionId, N'PENDING');

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT CAST(@DecisionId AS NVARCHAR(36)) AS DecisionId, @Status AS Status, CAST(0 AS BIT) AS Replayed;
END
GO

-- Attach a RAG citation to a decision.
CREATE OR ALTER PROCEDURE dbo.sp_CrewAi_Audit_AddSource
    @DecisionId UNIQUEIDENTIFIER,
    @Collection NVARCHAR(64),
    @PointId    NVARCHAR(128) = NULL,
    @Score      FLOAT = NULL,
    @Snippet    NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.AiDecisionSource (DecisionId, Collection, PointId, Score, Snippet)
    VALUES (@DecisionId, @Collection, @PointId, @Score, @Snippet);
END
GO

-- Read a single decision.
CREATE OR ALTER PROCEDURE dbo.sp_CrewAi_Audit_GetDecision
    @DecisionId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CAST(d.DecisionId AS NVARCHAR(36)) AS DecisionId, d.AgentKind, d.Status, d.Action,
           d.Target, d.RequiresApproval, d.Rationale, d.RequestedBy, d.CorrelationId,
           d.CreatedAt, d.UpdatedAt,
           a.ApprovalStatus, a.Approver, a.Reason, a.DecidedAt
      FROM dbo.AiDecision d
      LEFT JOIN dbo.AiApproval a ON a.DecisionId = d.DecisionId
     WHERE d.DecisionId = @DecisionId;
END
GO

-- Read the citations of a decision.
CREATE OR ALTER PROCEDURE dbo.sp_CrewAi_Audit_GetSources
    @DecisionId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Collection, PointId, Score, Snippet
      FROM dbo.AiDecisionSource
     WHERE DecisionId = @DecisionId
     ORDER BY Id ASC;
END
GO

-- List decisions awaiting approval (optionally filtered by agent).
CREATE OR ALTER PROCEDURE dbo.sp_CrewAi_Approval_ListPending
    @AgentKind NVARCHAR(32) = NULL,
    @Limit     INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @Limit IS NULL OR @Limit <= 0 SET @Limit = 50;
    SELECT TOP (@Limit)
           CAST(d.DecisionId AS NVARCHAR(36)) AS DecisionId, d.AgentKind, d.Status, d.Action,
           d.Target, d.RequiresApproval, d.Rationale, d.RequestedBy, d.CorrelationId, d.CreatedAt
      FROM dbo.AiDecision d
      INNER JOIN dbo.AiApproval a ON a.DecisionId = d.DecisionId
     WHERE a.ApprovalStatus = N'PENDING'
       AND (@AgentKind IS NULL OR d.AgentKind = @AgentKind)
     ORDER BY d.CreatedAt ASC;
END
GO

-- Approve/reject a pending action; flips the decision status accordingly.
CREATE OR ALTER PROCEDURE dbo.sp_CrewAi_Approval_SetStatus
    @DecisionId     UNIQUEIDENTIFIER,
    @ApprovalStatus NVARCHAR(16),     -- 'APPROVED' | 'REJECTED'
    @Approver       NVARCHAR(256),
    @Reason         NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ApprovalStatus NOT IN (N'APPROVED', N'REJECTED')
        THROW 50010, 'ApprovalStatus must be APPROVED or REJECTED.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.AiApproval
           SET ApprovalStatus = @ApprovalStatus, Approver = @Approver,
               Reason = @Reason, DecidedAt = SYSUTCDATETIME()
         WHERE DecisionId = @DecisionId AND ApprovalStatus = N'PENDING';

        IF @@ROWCOUNT = 0
            THROW 50011, 'No PENDING approval found for the given DecisionId.', 1;

        UPDATE dbo.AiDecision
           SET Status = CASE WHEN @ApprovalStatus = N'APPROVED' THEN N'EXECUTED' ELSE N'REJECTED' END,
               UpdatedAt = SYSUTCDATETIME()
         WHERE DecisionId = @DecisionId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    EXEC dbo.sp_CrewAi_Audit_GetDecision @DecisionId = @DecisionId;
END
GO

-- ---------- Least-privilege grant: EXEC only (no direct table access) ----------
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'crewai_app')
    CREATE USER [crewai_app] FOR LOGIN [crewai_app];
GO
GRANT EXECUTE ON SCHEMA::dbo TO [crewai_app];
GO
