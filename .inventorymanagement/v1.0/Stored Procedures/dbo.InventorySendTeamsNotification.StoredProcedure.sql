USE [ProdSpt_Inventory]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[InventorySendTeamsNotification]
    @AlertTitle nvarchar(255),
    @AlertMessage nvarchar(max),
    @AlertType nvarchar(100) = 'Information',
    @AlertLevel nvarchar(50) = 'INFO',
    @AlertData nvarchar(max) = NULL,
    @CertificateData nvarchar(max) = NULL,
    @WebhookUrl nvarchar(1024) = NULL,
    @DebugMode bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @JsonPayload nvarchar(max),
        @ResponseText nvarchar(max),
        @ErrorMsg nvarchar(max),
        @OuterErrorMessage nvarchar(4000),
        @OuterErrorSeverity int,
        @OuterErrorState int,
        @JobStartTime datetime = GETDATE(),
        @JobEndTime datetime,
        @Object int,
        @ResponseCode int,
        @AlertColor nvarchar(10) = 'BLUE',
        @DatabaseName nvarchar(128) = DB_NAME(),
        @ServerName nvarchar(128) = @@SERVERNAME,
        @WebhookName nvarchar(100) = 'Unknown Webhook';

    -- Set alert color based on level
    SET @AlertColor = CASE 
        WHEN @AlertLevel IN ('EXPIRED', 'CRITICAL', 'ERROR') THEN 'FF0000'  -- Red
        WHEN @AlertLevel IN ('WARNING', 'WARN') THEN 'FFA500'              -- Orange
        WHEN @AlertLevel IN ('INFO', 'INFORMATION') THEN '0078D4'          -- Blue
        WHEN @AlertLevel IN ('SUCCESS', 'OK') THEN '00FF00'                -- Green
        ELSE '808080'                                                       -- Gray
    END;

    -- Use default webhook URL if not provided
    IF @WebhookUrl IS NULL
    BEGIN
        -- Get webhook URL from teamsWebhooks table based on debug mode and alert type
        SELECT TOP 1 @WebhookUrl = WebhookUrl,
                     @WebhookName = Name
        FROM [dbo].[teamsWebhooks]
        WHERE IsActive = 1 AND IsDebug = @DebugMode
        ORDER BY 
            CASE 
                WHEN @AlertType IN ('Certificate Expiry Alert', 'Certificate System Error') AND Name LIKE '%Certificate%' THEN 1
                WHEN @AlertType NOT IN ('Certificate Expiry Alert', 'Certificate System Error') AND Name NOT LIKE '%Certificate%' THEN 1
                ELSE 2
            END,
            WebhookId;
        
        -- If no webhook found for the specific debug mode, try to get any active webhook
        IF @WebhookUrl IS NULL
        BEGIN
            SELECT TOP 1 @WebhookUrl = WebhookUrl,
                         @WebhookName = Name
            FROM [dbo].[teamsWebhooks]
            WHERE IsActive = 1
            ORDER BY 
                CASE WHEN IsDebug = @DebugMode THEN 0 ELSE 1 END,
                CASE 
                    WHEN @AlertType IN ('Certificate Expiry Alert', 'Certificate System Error') AND Name LIKE '%Certificate%' THEN 1
                    WHEN @AlertType NOT IN ('Certificate Expiry Alert', 'Certificate System Error') AND Name NOT LIKE '%Certificate%' THEN 1
                    ELSE 2
                END,
                WebhookId;
        END
    END
    ELSE
    BEGIN
        -- If webhook URL was provided, try to get the name from the table
        SELECT TOP 1 @WebhookName = Name
        FROM [dbo].[teamsWebhooks]
        WHERE WebhookUrl = @WebhookUrl AND IsActive = 1;
        
        -- If not found, use a generic name
        IF @WebhookName IS NULL OR @WebhookName = 'Unknown Webhook'
            SET @WebhookName = 'Custom Webhook';
    END

    DECLARE @WasEnabled bit;
    EXEC [dbo].[InventoryManageOleAutomation] 'ENABLE', @WasEnabled OUTPUT;

    BEGIN TRY
        -- Validate webhook URL
        IF @WebhookUrl IS NULL
        BEGIN
            SET @ErrorMsg = 'No active webhook URL found in teamsWebhooks table for debug mode: ' + CASE WHEN @DebugMode = 1 THEN 'True' ELSE 'False' END;
            
            -- Log the error
            INSERT INTO [dbo].[collectionLogs] (LogId, Timestamp, ScriptName, LogLevel, Message)
            VALUES (NEWID(), GETDATE(), 'InventorySendTeamsNotification', 'ERROR', @ErrorMsg);
            
            RAISERROR(@ErrorMsg, 16, 1);
            RETURN;
        END

        -- Create JSON payload for Teams notification
        -- Escape special characters in the message content
        DECLARE @EscapedMessage nvarchar(max) = @AlertMessage;
        SET @EscapedMessage = REPLACE(@EscapedMessage, '\', '\\');
        SET @EscapedMessage = REPLACE(@EscapedMessage, '"', '\"');
        SET @EscapedMessage = REPLACE(@EscapedMessage, CHAR(13), '\r');
        SET @EscapedMessage = REPLACE(@EscapedMessage, CHAR(10), '\n');
        SET @EscapedMessage = REPLACE(@EscapedMessage, CHAR(9), '\t');
        
        DECLARE @EscapedTitle nvarchar(255) = @AlertTitle;
        SET @EscapedTitle = REPLACE(@EscapedTitle, '\', '\\');
        SET @EscapedTitle = REPLACE(@EscapedTitle, '"', '\"');
        SET @EscapedTitle = REPLACE(@EscapedTitle, CHAR(13), '\r');
        SET @EscapedTitle = REPLACE(@EscapedTitle, CHAR(10), '\n');
        
        DECLARE @EscapedData nvarchar(max) = ISNULL(@AlertData, '');
        SET @EscapedData = REPLACE(@EscapedData, '\', '\\');
        SET @EscapedData = REPLACE(@EscapedData, '"', '\"');
        SET @EscapedData = REPLACE(@EscapedData, CHAR(13), '\r');
        SET @EscapedData = REPLACE(@EscapedData, CHAR(10), '\n');
        
        -- Build sections based on whether we have certificate data or not
        DECLARE @SectionsJson nvarchar(max) = '';
        
        IF @CertificateData IS NOT NULL AND LEN(@CertificateData) > 0
        BEGIN
            -- Parse certificate data in pipe-delimited format
            -- Format: Subject1|SectionText1||Subject2|SectionText2||...
            DECLARE @CertDataToParse nvarchar(max) = @CertificateData;
            DECLARE @SectionCount int = 0;
            DECLARE @Pos int = 1;
            DECLARE @NextPos int;
            DECLARE @CertSection nvarchar(max);
            DECLARE @Subject nvarchar(500);
            DECLARE @SectionText nvarchar(max);
            DECLARE @PipePos int;
            
            -- Split by double pipes to get individual certificate sections
            WHILE @Pos <= LEN(@CertDataToParse)
            BEGIN
                SET @NextPos = CHARINDEX('||', @CertDataToParse, @Pos);
                IF @NextPos = 0
                    SET @NextPos = LEN(@CertDataToParse) + 1;
                
                SET @CertSection = SUBSTRING(@CertDataToParse, @Pos, @NextPos - @Pos);
                
                -- Split by single pipe to get subject and section text
                SET @PipePos = CHARINDEX('|', @CertSection);
                IF @PipePos > 0
                BEGIN
                    SET @Subject = SUBSTRING(@CertSection, 1, @PipePos - 1);
                    SET @SectionText = SUBSTRING(@CertSection, @PipePos + 1, LEN(@CertSection) - @PipePos);
                    
                    -- Escape the section text for JSON
                    SET @SectionText = REPLACE(@SectionText, '\', '\\');
                    SET @SectionText = REPLACE(@SectionText, '"', '\"');
                    -- For Teams, preserve markdown line breaks (two spaces + newline)
                    SET @SectionText = REPLACE(@SectionText, CHAR(13), '');
                    SET @SectionText = REPLACE(@SectionText, CHAR(10), '\n');
                    
                    -- Escape the subject for JSON
                    SET @Subject = REPLACE(@Subject, '\', '\\');
                    SET @Subject = REPLACE(@Subject, '"', '\"');
                    
                    -- Add section to JSON
                    IF @SectionCount > 0
                        SET @SectionsJson = @SectionsJson + ',';
                    
                    SET @SectionsJson = @SectionsJson + '
        {
            "activityTitle": "Certificate Expiry Monitor (' + @AlertLevel + ')",
            "activitySubtitle": "' + @Subject + '",
            "text": "' + @SectionText + '"
        }';
                    
                    SET @SectionCount = @SectionCount + 1;
                END
                
                SET @Pos = @NextPos + 2; -- Skip the double pipe
                
                -- Safety check to prevent infinite loop
                IF @NextPos >= LEN(@CertDataToParse)
                    BREAK;
            END
        END
        
        -- If no certificate data or parsing failed, use fallback
        IF @SectionsJson = ''
        BEGIN
            SET @SectionsJson = '
        {
            "activityTitle": "Certificate Expiry Monitor (' + @AlertLevel + ')",
            "activitySubtitle": "Review and renew expiring certificates",
            "text": "' + @EscapedMessage + '",
            "facts": [
                {
                    "name": "Alert Level",
                    "value": "' + @AlertLevel + '"
                },
                {
                    "name": "Alert Type",
                    "value": "' + @AlertType + '"
                },
                {
                    "name": "Server",
                    "value": "' + @ServerName + '"
                },
                {
                    "name": "Database",
                    "value": "' + @DatabaseName + '"
                },
                {
                    "name": "Timestamp",
                    "value": "' + CONVERT(varchar(30), GETDATE(), 121) + '"
                }' + 
                CASE 
                    WHEN @AlertData IS NOT NULL AND LEN(@AlertData) > 0 THEN ',
                {
                    "name": "Additional Data",
                    "value": "' + @EscapedData + '"
                }'
                    ELSE ''
                END + '
            ]
        }';
        END
        ELSE
        BEGIN
            -- Add comprehensive footer information
            SET @SectionsJson = @SectionsJson + ',
        {
            "text": "**Repository Path:** \\\\cir\\\\files\\\\Departments\\\\Technology\\\\IT\\\\Certificates  ' + CHAR(13) + CHAR(10) + '**Alert Criteria:** Certificates expiring within 30 days  ' + CHAR(13) + CHAR(10) + '**Sources:** Repository, OS Store, IIS, F5 Load Balancer  ' + CHAR(13) + CHAR(10) + '**Critical Threshold:** 7 days | **Warning Threshold:** 30 days  ' + CHAR(13) + CHAR(10) + '**Database:** ' + @DatabaseName + ' | **Server:** ' + @ServerName + '  ' + CHAR(13) + CHAR(10) + '**Generated:** ' + CONVERT(varchar(30), GETDATE(), 121) + '"
        }';
        END
        
        SET @JsonPayload = N'{
    "text": "' + @EscapedTitle + '",
    "themeColor": "' + @AlertColor + '",
    "summary": "' + @AlertType + ' Alert from ' + @ServerName + '",
    "sections": [' + @SectionsJson + '
    ]
}';

        -- Send the notification to Teams
        BEGIN TRY
            EXEC sp_OACreate 'MSXML2.XMLHTTP', @Object OUT;
            EXEC sp_OAMethod @Object, 'open', NULL, 'POST', @WebhookUrl, 'false';
            EXEC sp_OAMethod @Object, 'setRequestHeader', NULL, 'Content-Type', 'application/json';
            EXEC sp_OAMethod @Object, 'send', NULL, @JsonPayload;
            EXEC sp_OAGetProperty @Object, 'status', @ResponseCode OUT;
            EXEC sp_OAGetProperty @Object, 'responseText', @ResponseText OUT;
            EXEC sp_OADestroy @Object;

            IF @ResponseCode BETWEEN 200 AND 299
            BEGIN
                -- Log successful notification
                INSERT INTO [dbo].[collectionLogs]
                    (LogId, Timestamp, ScriptName, LogLevel, Message, AdditionalInfo)
                VALUES
                    (NEWID(), GETDATE(), 'InventorySendTeamsNotification', 'INFO', 
                     'Teams notification sent successfully for: ' + @AlertTitle, 
                     'Alert Type: ' + @AlertType + ', Level: ' + @AlertLevel + ', Response Code: ' + CAST(@ResponseCode AS nvarchar(10)) + ', Webhook: ' + @WebhookName);
            END
            ELSE
            BEGIN
                SET @ErrorMsg = 'Failed to send Teams notification. Status code: ' + CAST(@ResponseCode AS nvarchar(10));
                INSERT INTO [dbo].[collectionLogs]
                    (LogId, Timestamp, ScriptName, LogLevel, Message, AdditionalInfo)
                VALUES
                    (NEWID(), GETDATE(), 'InventorySendTeamsNotification', 'ERROR', 
                     @ErrorMsg, 
                     'Alert: ' + @AlertTitle + ', Webhook: ' + @WebhookName + ', Response: ' + ISNULL(@ResponseText, 'No response text'));
                
                IF @DebugMode = 1
                BEGIN
                    INSERT INTO [dbo].[collectionLogs]
                        (LogId, Timestamp, ScriptName, LogLevel, Message, AdditionalInfo)
                    VALUES
                        (NEWID(), GETDATE(), 'InventorySendTeamsNotification', 'DEBUG', 
                         'JSON Payload for failed request', 
                         @JsonPayload);
                END
            END
        END TRY
        BEGIN CATCH
            SET @ErrorMsg = ERROR_MESSAGE();
            INSERT INTO [dbo].[collectionLogs]
                (LogId, Timestamp, ScriptName, LogLevel, Message, AdditionalInfo)
            VALUES
                (NEWID(), GETDATE(), 'InventorySendTeamsNotification', 'ERROR', 
                 'Exception during Teams notification for: ' + @AlertTitle, 
                 @ErrorMsg);
            
            IF @DebugMode = 1
            BEGIN
                INSERT INTO [dbo].[collectionLogs]
                    (LogId, Timestamp, ScriptName, LogLevel, Message, AdditionalInfo)
                VALUES
                    (NEWID(), GETDATE(), 'InventorySendTeamsNotification', 'DEBUG', 
                     'JSON Payload for exception', 
                     @JsonPayload);
            END
            
            RAISERROR(@ErrorMsg, 16, 1);
        END CATCH

    END TRY
    BEGIN CATCH
        SET @OuterErrorMessage = ERROR_MESSAGE();
        SET @OuterErrorSeverity = ERROR_SEVERITY();
        SET @OuterErrorState = ERROR_STATE();
    END CATCH

    -- Cleanup: Disable Ole Automation if it wasn't enabled before
    IF @WasEnabled = 0
        EXEC [dbo].[InventoryManageOleAutomation] 'DISABLE', @WasEnabled OUTPUT;

    -- Re-raise any outer errors
    IF @OuterErrorMessage IS NOT NULL
        RAISERROR(@OuterErrorMessage, @OuterErrorSeverity, @OuterErrorState);

    -- Log completion
    SET @JobEndTime = GETDATE();
    INSERT INTO [dbo].[collectionLogs]
        (LogId, Timestamp, ScriptName, LogLevel, Message, AdditionalInfo)
    VALUES
        (NEWID(), GETDATE(), 'InventorySendTeamsNotification', 'INFO', 
         'InventorySendTeamsNotification completed for: ' + @AlertTitle, 
         'Duration: ' + CAST(DATEDIFF(SECOND, @JobStartTime, @JobEndTime) AS NVARCHAR(10)) + ' seconds');
END
GO