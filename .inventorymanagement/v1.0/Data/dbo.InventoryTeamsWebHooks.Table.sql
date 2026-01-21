USE [ProdSpt_Inventory]
GO

-- Drop existing table if it exists
IF EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[teamsWebhooks]') AND type in (N'U'))
BEGIN
    DROP TABLE [dbo].[teamsWebhooks]
    PRINT 'Existing teamsWebhooks table dropped'
END
GO

/****** Object:  Table [dbo].[teamsWebhooks]    Script Date: 7/15/2025 12:34:23 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[teamsWebhooks](
	[WebhookId] [int] IDENTITY(1,1) NOT NULL,
	[Name] [nvarchar](100) NOT NULL,
	[WebhookUrl] [nvarchar](1024) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[IsDebug] [bit] NOT NULL,
	[Description] [nvarchar](500) NULL,
	[CreatedDate] [datetime] NOT NULL,
	[LastModified] [datetime] NULL,
	[TeamName] [nvarchar](100) NULL,
 CONSTRAINT [PK_TeamsWebhooks] PRIMARY KEY CLUSTERED 
(
	[WebhookId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
PRINT 'teamsWebhooks table created'
-- Insert initial webhook data
SET IDENTITY_INSERT [dbo].[teamsWebhooks] ON 
GO
INSERT [dbo].[teamsWebhooks] ([WebhookId], [Name], [WebhookUrl], [IsActive], [IsDebug], [Description], [CreatedDate], [LastModified], [TeamName]) VALUES (1, N'IS Release Notifications', N'https://REDACTED_TEAMS_WEBHOOK_URL_1', 1, 0, N'Production webhook for IS Department release notifications and system alerts', GETDATE(), GETDATE(), N'IS Department')
GO
INSERT [dbo].[teamsWebhooks] ([WebhookId], [Name], [WebhookUrl], [IsActive], [IsDebug], [Description], [CreatedDate], [LastModified], [TeamName]) VALUES (2, N'Production Support Debug', N'https://REDACTED_TEAMS_WEBHOOK_URL_2', 1, 1, N'Debug webhook for Production Support Department testing and development alerts', GETDATE(), GETDATE(), N'Production Support')
GO
INSERT [dbo].[teamsWebhooks] ([WebhookId], [Name], [WebhookUrl], [IsActive], [IsDebug], [Description], [CreatedDate], [LastModified], [TeamName]) VALUES (3, N'ProdSpt Certificate Notifications', N'https://REDACTED_TEAMS_WEBHOOK_URL_3', 1, 0, N'Production webhook for Production Support Department certificate expiry notifications and alerts', GETDATE(), GETDATE(), N'Production Support')
GO
SET IDENTITY_INSERT [dbo].[teamsWebhooks] OFF
GO
PRINT 'Initial webhook data inserted'
-- Add table constraints and defaults
ALTER TABLE [dbo].[teamsWebhooks] ADD  CONSTRAINT [DF_TeamsWebhooks_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO
ALTER TABLE [dbo].[teamsWebhooks] ADD  CONSTRAINT [DF_TeamsWebhooks_IsDebug]  DEFAULT ((0)) FOR [IsDebug]
GO
ALTER TABLE [dbo].[teamsWebhooks] ADD  CONSTRAINT [DF_TeamsWebhooks_CreatedDate]  DEFAULT (getdate()) FOR [CreatedDate]
GO
PRINT 'Table constraints and defaults added'

-- Verify table creation and data
SELECT 
    WebhookId,
    Name,
    CASE WHEN IsActive = 1 THEN 'Active' ELSE 'Inactive' END as Status,
    CASE WHEN IsDebug = 1 THEN 'Debug' ELSE 'Production' END as Mode,
    TeamName,
    CreatedDate
FROM [dbo].[teamsWebhooks]
ORDER BY WebhookId

PRINT 'teamsWebhooks table setup completed successfully'
