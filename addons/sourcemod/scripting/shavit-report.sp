#include <sourcemod>
#include <shavit/core>
#include <shavit/reports>
#include <shavit/wr>
#include <shavit/replay-playback>
#include <shavit/steamid-stocks>

#undef REQUIRE_PLUGIN
#include <discord>

#pragma newdecls required
#pragma semicolon 1

//
//// Globals
//

Database gH_SQL = null;
ArrayList gH_Reports;
report_t gH_Auditing[MAXPLAYERS + 1];
stylestrings_t gS_StyleStrings[STYLE_LIMIT];
chatstrings_t gS_ChatStrings;
ConVar gCS_BanReason;
ConVar gCS_BlacklistReason;
ConVar gCF_BanDuration;
ConVar gCF_BlacklistDuration;
ConVar gCS_WebhookURL;
char gS_SQLPrefix[32];
char gS_MapName[PLATFORM_MAX_PATH];
int gI_ActiveReport[MAXPLAYERS + 1];
int gI_MenuTrack[MAXPLAYERS + 1];
int gI_MenuStyle[MAXPLAYERS + 1];
int gI_Blacklist[MAXPLAYERS + 1] = { -1, ... };
int gI_Styles;
bool gB_Chat[MAXPLAYERS + 1];
bool gB_Late    = false;
bool gB_Discord = false;

char gS_Reasons[5][64] = {
    "Improper Zones (Start)",
    "Improper Zones (End)",
    "Bugged Record",
    "Cheated Record",
    "Other",
};

//
//// Plugin Setup
//
public Plugin myinfo =
{
    name        = "[shavit] Reporting System",
    author      = "MSWS",
    description = "Create and handle record reports",
    version     = SHAVIT_VERSION,
    url         = "https://github.com/MSWS/bhop-reports"
};

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int err) {
    gB_Late = late;
    return APLRes_Success;
}

public void OnPluginStart() {
    gH_Reports = new ArrayList(sizeof(report_t));

    LoadTranslations("shavit-report.phrases");
    LoadTranslations("shavit-common.phrases");

    RegAdminCmd("sm_reports", Command_Reports, ADMFLAG_BAN, "View player reports");
    RegAdminCmd("sm_audit", Command_AuditReport, ADMFLAG_CHEATS, "Audit reports");
    RegAdminCmd("sm_auditreport", Command_AuditReport, ADMFLAG_CHEATS, "Audit reports");
    RegAdminCmd("sm_reportstats", Command_ReportStats, ADMFLAG_GENERIC, "View report stats");
    RegConsoleCmd("sm_report", Command_Report, "Report a player's record");

    gCS_BanReason         = CreateConVar("shavit_reports_reason", "#{id} Record Violation", "Report ban reason");
    gCS_BlacklistReason   = CreateConVar("shavit_blacklist_reason", "#{id} Report Violation", "Report blacklist reason");
    gCF_BanDuration       = CreateConVar("shavit_reports_bantime", "40320", "Default ban duration", _, true, -1.0, true, 120960.0);
    gCF_BlacklistDuration = CreateConVar("shavit_blacklist_bantime", "10080", "Default blacklist duration", _, true, -1.0, true, 120960.0);
    gCS_WebhookURL        = CreateConVar("shavit_reports_webhook", "", "Webhook URL for Discord integration");

    AutoExecConfig();
    GetTimerSQLPrefix(gS_SQLPrefix, sizeof(gS_SQLPrefix));
    gH_SQL = GetTimerDatabaseHandle();

    if (gB_Late) {
        Shavit_OnStyleConfigLoaded(Shavit_GetStyleCount());
        Shavit_OnChatConfigLoaded();
        for (int i = 1; i <= MaxClients; i++) {
            if (IsClientInGame(i) && !IsFakeClient(i))
                SQL_CheckBlacklist(i);
        }
    }

    SQL_CreateSQL();
}

//
//// Plugin Initialization
//
public void OnMapStart() {
    GetCurrentMap(gS_MapName, sizeof(gS_MapName));
    SQL_LoadReports();
}

public Action OnClientSayCommand(int client, const char[] cmd, const char[] args) {
    if (!gB_Chat[client])
        return Plugin_Continue;
    gB_Chat[client] = false;
    FakeClientCommand(client, "sm_report %d %d %s", gI_MenuTrack[client], gI_MenuStyle[client], args);
    return Plugin_Stop;
}

public void OnClientConnected(int client) {
    gI_Blacklist[client] = -1;
    SQL_CheckBlacklist(client);
}

public void OnAllPluginsLoaded() {
    gB_Discord = LibraryExists("discord-api");
}

public void OnLibraryAdded(const char[] name) {
    if (StrEqual(name, "discord-api"))
        gB_Discord = true;
}

public void OnLibraryRemoved(const char[] name) {
    if (StrEqual(name, "discord-api"))
        gB_Discord = false;
}

//
//// Shavit Hooks
//
public void Shavit_OnStyleConfigLoaded(int styles) {
    for (int i = 0; i < styles; i++)
        Shavit_GetStyleStringsStruct(i, gS_StyleStrings[i]);
    gI_Styles = styles;
}

public void Shavit_OnChatConfigLoaded() {
    Shavit_GetChatStringsStruct(gS_ChatStrings);
}

//
//// SQL Functions
//

void SQL_LoadResolutions(Database db, DBResultSet results, const char[] error, DataPack data) {
    if (results == null) {
        LogError("SQL error! Reason: %s", error);
        return;
    }
    data.Reset();
    char title[32];
    int client = data.ReadCell();
    data.ReadString(title, sizeof(title));
    delete data;
    Panel panel = new Panel();
    panel.SetTitle(title);
    char line[32];
    while (results.FetchRow()) {
        int resolution = results.FetchInt(0);
        int count      = results.FetchInt(1);
        Format(line, sizeof(line), "%s: %d", resolution == -1 ? "Unhandled" : gS_Resolutions[resolution], count);
        panel.DrawText(line);
    }
    panel.DrawItem("Back");
    panel.Send(client, MenuHandler_ReportStatsGeneric, MENU_TIME_FOREVER);
}

void SQL_LoadStringInt(Database db, DBResultSet results, const char[] error, DataPack data) {
    if (results == null) {
        LogError("SQL error! Reason: %s", error);
        return;
    }
    data.Reset();
    char title[32];
    int client = data.ReadCell();
    data.ReadString(title, sizeof(title));
    delete data;
    Menu menu = new Menu(MenuHandler_ReportStatsGeneric);
    menu.SetTitle(title);
    char line[64];
    while (results.FetchRow()) {
        char name[MAX_NAME_LENGTH];
        results.FetchString(0, name, sizeof(name));
        Format(line, sizeof(line), "%s: %d", name, results.FetchInt(1));
        menu.AddItem("", line, ITEMDRAW_DISABLED);
    }
    menu.Display(client, MENU_TIME_FOREVER);
}

void SQL_CreateSQL() {
    char sQuery[512];
    FormatEx(sQuery, sizeof(sQuery),
      "CREATE TABLE IF NOT EXISTS `%sreports` (`id` INT AUTO_INCREMENT NOT NULL, `recordId` INT NOT NULL, `reporter` INT NOT NULL, `reason` VARCHAR(128) NOT NULL, `date` TIMESTAMP NOT NULL DEFAULT NOW(), `handler` INT, `resolution` INT DEFAULT -1, `handledDate` TIMESTAMP, PRIMARY KEY (`id`), FOREIGN KEY (`reporter`) REFERENCES %susers(`auth`), FOREIGN KEY (`recordId`) REFERENCES %splayertimes(`id`) ON DELETE CASCADE, FOREIGN KEY (`handler`) REFERENCES %susers(`auth`));",
      gS_SQLPrefix, gS_SQLPrefix, gS_SQLPrefix, gS_SQLPrefix);
    QueryLog(gH_SQL, SQL_Void, sQuery);
}

void SQL_LoadReports() {
    LogMessage("Loading reports...");
    gH_Reports.Clear();
    char sQuery[1024];
    FormatEx(sQuery, sizeof(sQuery), "SELECT `report`.*, `clients`.`name` AS 'Recorder', `reportClient`.`name` AS 'Reporter', `times`.`track` , `times`.`style`, `handlerClient`.`name` AS Handler, `times`.`time` FROM `playertimes` AS times INNER JOIN `%sreports` AS report ON (report.recordId=times.id) INNER JOIN `users` AS clients ON (times.auth = clients.auth) LEFT JOIN `users` AS reportClient ON (report.reporter=reportClient.auth) LEFT JOIN `users` AS handlerClient ON (report.handler=handlerClient.auth) WHERE `handler` IS NULL AND `map` = '%s';", gS_SQLPrefix, gS_MapName);
    QueryLog(gH_SQL, SQL_LoadedReports, sQuery, -1);
}

void SQL_AuditReport(int client, int report) {
    char sQuery[1024];
    FormatEx(sQuery, sizeof(sQuery), "SELECT `report`.*, `clients`.`name` AS 'Recorder', `reportClient`.`name` AS 'Reporter', `times`.`track` , `times`.`style`, `handlerClient`.`name` AS Handler, `times`.`time` FROM `playertimes` AS times INNER JOIN `%sreports` AS report ON (report.recordId=times.id) INNER JOIN `users` AS clients ON (times.auth = clients.auth) LEFT JOIN `users` AS reportClient ON (report.reporter=reportClient.auth) LEFT JOIN `users` AS handlerClient ON (report.handler=handlerClient.auth) WHERE `report`.`id` = '%d';", gS_SQLPrefix, report);
    QueryLog(gH_SQL, SQL_AuditLoaded, sQuery, client);
}

void SQL_FetchReportStats(int client) {
    char sQuery[256];
    FormatEx(sQuery, sizeof(sQuery), "SELECT COUNT(*), COUNT(CASE WHEN `handler` IS NULL THEN NULL ELSE 1 END) FROM `reports`;", gS_SQLPrefix);
    QueryLog(gH_SQL, SQL_LoadedTotalStats, sQuery, client);
}

void SQL_LoadedTotalStats(Database db, DBResultSet results, const char[] error, int client) {
    if (results == null) {
        LogError("Timer error! Failed to load report data. Reason: %s", error);
        return;
    }
    if (!results.FetchRow()) {
        Shavit_PrintToChat(client, "%T", "UnknownError", client, gS_ChatStrings.sWarning, "No report data found", gS_ChatStrings.sWarning);
        return;
    }
    int total   = results.FetchInt(0);
    int handled = results.FetchInt(1);
    Menu menu   = CreateMenu(MenuHandler_ReportStats);

    menu.SetTitle("Report Stats\nHandled: %d/%d (%.2f%%)", handled, total, (float(handled) / total) * 100.0);
    menu.AddItem("reporters", "Reporters");
    menu.AddItem("reported", "Reported");
    menu.AddItem("accuracy", "Accuracy");
    menu.AddItem("handlers", "Handlers");
    menu.AddItem("maps", "Maps");
    menu.AddItem("resolutions", "Resolutions");
    menu.Display(client, MENU_TIME_FOREVER);
}

void SQL_LoadedReports(Database db, DBResultSet results, const char[] error, int reporter = -1) {
    if (results == null) {
        LogError("Timer error! Failed to load report data. Reason: %s", error);
        return;
    }

    while (results.FetchRow()) {
        report_t report;
        LoadReport(results, report);
        gH_Reports.PushArray(report);
        if (reporter != -1) {
            Shavit_PrintToChat(reporter, "%T", "ReportSubmittedID", reporter, gS_ChatStrings.sVariable, report.id, gS_ChatStrings.sText);
            LogMessage("Discord: %b", gB_Discord);
            if (gB_Discord)
                PostWebhook(report);
        }
    }

    if (reporter == -1)
        LogMessage("Loaded %d reports", gH_Reports.Length);
}

void SQL_AuditLoaded(Database db, DBResultSet results, const char[] error, int client) {
    if (results == null) {
        LogError("Timer error! Failed to load report data. Reason: %s", error);
        Shavit_PrintToChat(client, "%T", "UnknownError", client, gS_ChatStrings.sWarning, error, gS_ChatStrings.sText);
        return;
    }

    if (!results.FetchRow()) {
        Shavit_PrintToChat(client, "%T", "UnknownError", client, gS_ChatStrings.sWarning, "Invalid report ID", gS_ChatStrings.sText);
        return;
    }

    report_t report;
    LoadReport(results, report);
    OpenReportAuditMenu(client, report);
}

void SQL_UploadReport(report_t report, int client) {
    char sQuery[512];
    gH_SQL.Escape(report.reason, report.reason, sizeof(report.reason));
    FormatEx(sQuery, sizeof(sQuery), "INSERT INTO `%sreports` (`recordId`, `reporter`, `reason`) VALUES('%d', '%d', '%s');", gS_SQLPrefix, report.recordId, report.reporter, report.reason);
    LogMessage("SQL: %s", sQuery);

    DataPack pack = new DataPack();
    pack.WriteCellArray(report, sizeof(report_t));
    pack.WriteCell(client);

    QueryLog(gH_SQL, SQL_Uploaded, sQuery, pack);
}

void SQL_UpdateReport(report_t report, int client = -1) {
    char sQuery[1024];
    FormatEx(sQuery, sizeof(sQuery), "SELECT `report`.*, `clients`.`name` AS 'Recorder', `reportClient`.`name` AS 'Reporter', `times`.`track` , `times`.`style`, `handlerClient`.`name` AS Handler, `times`.`time` FROM `playertimes` AS times INNER JOIN `%sreports` AS report ON (report.recordId=times.id) INNER JOIN `users` AS clients ON (times.auth = clients.auth) LEFT JOIN `users` AS reportClient ON (report.reporter=reportClient.auth) LEFT JOIN `users` AS handlerClient ON (report.handler=handlerClient.auth) WHERE `reason` = '%s' AND `reporter` = '%d' ORDER BY `date` DESC LIMIT 1;", gS_SQLPrefix, report.reason, report.reporter);
    LogMessage("SQL: %s", sQuery);
    QueryLog(gH_SQL, SQL_LoadedReports, sQuery, client);
}

void SQL_ResolveReport(int client, Resolution resolution) {
    report_t report;
    if (gI_ActiveReport[client] == -1) {
        Shavit_PrintToChat(client, "%T", "UnknownError", gS_ChatStrings.sWarning, "Invalid report ID", gS_ChatStrings.sText);
        return;
    }
    gH_Reports.GetArray(gI_ActiveReport[client], report);
    switch (resolution) {
        case DELETE: {
            Shavit_DeleteWR(report.style, report.track, gS_MapName, -1, -1, true, true);
            Shavit_PrintToChat(client, "%T", "ReportHandleAccept", client, gS_ChatStrings.sVariable, report.id, gS_ChatStrings.sText, gS_ChatStrings.sWarning, report.targetName, gS_ChatStrings.sText);
        }
        case BAN: {
            Shavit_DeleteWR(report.style, report.track, gS_MapName, -1, -1, true, true);
            Shavit_PrintToChat(client, "%T", "ReportHandleBan", client, gS_ChatStrings.sVariable, report.id, gS_ChatStrings.sText, gS_ChatStrings.sWarning, report.targetName, gS_ChatStrings.sText);
            char sid[MAX_AUTHID_LENGTH], reason[64], sId[8];
            gCS_BanReason.GetString(reason, sizeof(reason));
            IntToString(report.id, sId, sizeof(sId));
            ReplaceString(reason, sizeof(reason), "{id}", sId);
            AccountIDToSteamID64(report.reported, sid, sizeof(sid));
            FakeClientCommand(client, "sm_addban %s %d %s", sid, RoundFloat(gCF_BanDuration.FloatValue), reason);
        }
        case WIPE: {
            char buff[32];
            AccountIDToSteamID64(report.reported, buff, sizeof(buff));
            FakeClientCommand(client, "sm_wipeplayer %s", buff);
            Shavit_PrintToChat(client, "%T", "ReportHandleWipe", client, gS_ChatStrings.sVariable, report.id, gS_ChatStrings.sText, gS_ChatStrings.sWarning, report.targetName, gS_ChatStrings.sText);
        }
        case REJECT:
            Shavit_PrintToChat(client, "%T", "ReportHandleReject", client, gS_ChatStrings.sVariable, report.id, gS_ChatStrings.sText);

        case BLACKLIST: {
            Shavit_PrintToChat(client, "%T", "ReportHandleBlacklist", client, gS_ChatStrings.sVariable, report.id, gS_ChatStrings.sText, gS_ChatStrings.sWarning, report.reporterName, gS_ChatStrings.sText);
            for (int i = 1; i <= MaxClients; i++) {
                if (!IsClientInGame(i) || report.reporter != GetSteamAccountID(i))
                    continue;
                gI_Blacklist[i] = report.id;
                break;
            }
            // Blacklist reporter
        }
        case BLACKBAN: {
            char sid[MAX_AUTHID_LENGTH], reason[64], sId[8];
            gCS_BlacklistReason.GetString(reason, sizeof(reason));
            IntToString(report.id, sId, sizeof(sId));
            ReplaceString(reason, sizeof(reason), "{id}", sId);
            AccountIDToSteamID64(report.reporter, sid, sizeof(sid));
            FakeClientCommand(client, "sm_addban %s %d %s", sid, RoundFloat(gCF_BlacklistDuration.FloatValue), reason);
            Shavit_PrintToChat(client, "%T", "ReportHandleBlackban", client, gS_ChatStrings.sVariable, report.id, gS_ChatStrings.sText, gS_ChatStrings.sWarning, report.reporterName, gS_ChatStrings.sText);
        }
        default: {
            Shavit_PrintToChat(client, "%T", "UnknownError", client, gS_ChatStrings.sWarning, "Invalid MenuItem", gS_ChatStrings.sText);
            return;
        }
    }

    char sQuery[256];

    // id recordId reporter reason `date` handler resolution handledDate Recorder Reporter track `style`
    report.handler = GetSteamAccountID(client);
    Format(sQuery, sizeof(sQuery),
      "UPDATE `%sreports` SET `handler` = '%d', `resolution` = '%d', `handledDate` = NOW() WHERE `id` = '%d';",
      gS_SQLPrefix, report.handler, view_as<int>(resolution), report.id);
    QueryLog(gH_SQL, SQL_Void, sQuery);
    gH_Reports.Erase(gI_ActiveReport[client]);
    for (int i = 1; i <= MaxClients; i++) {
        int active = gI_ActiveReport[i];
        if (active == gI_ActiveReport[client])
            gI_ActiveReport[i] = -1;
        if (active > gI_ActiveReport[client])
            gI_ActiveReport[i]--;
    }
    gI_ActiveReport[client] = 0;
}

void SQL_CheckBlacklist(int client) {
    char sQuery[256];
    Format(sQuery, sizeof(sQuery),
      "SELECT `id` FROM `%sreports` WHERE `reporter` = '%d' AND `resolution` = '%d' AND `handledDate` > DATE_SUB(NOW(), INTERVAL %d MINUTE) ORDER BY `handledDate` DESC LIMIT 1;",
      gS_SQLPrefix, GetSteamAccountID(client), view_as<int>(BLACKLIST), RoundFloat(gCF_BlacklistDuration.FloatValue));
    QueryLog(gH_SQL, SQL_BlacklistCheck, sQuery, client);
}

void SQL_BlacklistCheck(Database db, DBResultSet results, const char[] error, int client) {
    if (results == null) {
        LogError("Timer error! Failed to load report data. Reason: %s", error);
        return;
    }
    if (!results.FetchRow()) {
        gI_Blacklist[client] = 0;
        return;
    }
    gI_Blacklist[client] = results.FetchInt(0);
}

void SQL_Void(Database db, DBResultSet results, const char[] error, DataPack hPack) {
    if (results == null)
        LogError("SQL error! Reason: %s", error);
}

void SQL_Uploaded(Database db, DBResultSet results, const char[] error, DataPack hPack) {
    if (results == null)
        LogError("SQL error! Reason: %s", error);
    hPack.Reset();
    report_t report;
    hPack.ReadCellArray(report, sizeof(report_t));
    int client = hPack.ReadCell();
    SQL_UpdateReport(report, client);
    delete hPack;
}

//
//// Commands
//
public Action Command_Reports(int client, int args) {
    if (gH_Reports.Length == 0) {
        Shavit_PrintToChat(client, "%T", "NoReports", client, gS_ChatStrings.sVariable2);
        return Plugin_Handled;
    }
    gI_ActiveReport[client] = -1;
    int reportId            = -1;
    if (args == 1) {
        char sId[3];
        GetCmdArg(1, sId, sizeof(sId));
        reportId = StringToInt(sId);
        if (reportId < 0 || reportId >= gH_Reports.Length)
            return Plugin_Handled;
        gI_ActiveReport[client] = reportId;
    }
    OpenReportViewMenu(client, reportId);
    return Plugin_Handled;
}

// sm_report [track] [style] [reason]
public Action Command_Report(int client, int args) {
    if (gI_Blacklist[client] != 0) {
        Shavit_PrintToChat(client, "%T", "Blacklisted", client, gS_ChatStrings.sWarning, gS_ChatStrings.sText, gS_ChatStrings.sVariable, gI_Blacklist[client], gS_ChatStrings.sText);
        return Plugin_Handled;
    }

    if (args == 0 && IsClientInGame(client)) {
        OpenReportTrackMenu(client);
        return Plugin_Handled;
    }

    char command[256];
    GetCmdArgString(command, sizeof(command));
    char sArgs[3][128];
    ExplodeString(command, " ", sArgs, sizeof(sArgs), sizeof(sArgs[]), true);

    if (args == 1) {
        OpenReportStyleMenu(client, gI_MenuTrack[client]);
        return Plugin_Handled;
    }

    if (args == 2) {
        OpenReportReasonMenu(client);
        return Plugin_Handled;
    }

    report_t report;
    int track = StringToInt(sArgs[0]), style = StringToInt(sArgs[1]);
    Shavit_GetWRRecordID(style, report.recordId, track);
    if (report.recordId == -1) {
        Shavit_PrintToChat(client, "%T", "UnknownRecord", client, gS_ChatStrings.sWarning, gS_ChatStrings.sText);
        return Plugin_Handled;
    }

    report.date     = GetTime();
    report.reporter = GetSteamAccountID(client);
    strcopy(report.reason, sizeof(report.reason), sArgs[2]);

    SQL_UploadReport(report, client);
    Shavit_PrintToChat(client, "%T", "ReportSubmitted", client);
    return Plugin_Handled;
}

public Action Command_AuditReport(int client, int args) {
    if (!IsClientInGame(client))
        return Plugin_Handled;

    if (args == 0) {
        Shavit_PrintToChat(client, "Please specify a report ID.");
        return Plugin_Handled;
    }
    char sId[8];
    GetCmdArg(1, sId, sizeof(sId));
    SQL_AuditReport(client, StringToInt(sId));
    return Plugin_Handled;
}

public Action Command_ReportStats(int client, int args) {
    if (!IsClientInGame(client))
        return Plugin_Handled;
    SQL_FetchReportStats(client);
    return Plugin_Handled;
}

//
//// Menu
//

void OpenReportViewMenu(int client, int reportIndex = -1) {
    if (reportIndex == -1) {
        Menu menu = new Menu(MenuHandler_ReportView);
        menu.SetTitle("%T\n ", "ReportViewTitle", client);
        for (int i = 0; i < gH_Reports.Length && i < 50; i++) {
            report_t report;
            gH_Reports.GetArray(i, report);
            char line[64];
            char trackName[32];
            GetTrackName(client, report.track, trackName, sizeof(trackName));
            char sTime[32];
            float time = Shavit_GetWorldRecord(report.style, report.track);
            FormatSeconds(time, sTime, sizeof(sTime), false);
            Format(line, sizeof(line), "%s > %s's %s %s (%s)", report.reporterName, report.targetName, gS_StyleStrings[report.style], trackName, sTime);
            char ind[3];
            IntToString(i, ind, sizeof(ind));
            menu.AddItem(ind, line);
        }
        menu.Display(client, MENU_TIME_FOREVER);
        return;
    }
    report_t report;
    gH_Reports.GetArray(reportIndex, report);
    Menu menu = new Menu(MenuHandler_ReportAction);
    char trackName[32], sTime[32];
    GetTrackName(client, report.track, trackName, sizeof(trackName));
    FormatSeconds(report.time, sTime, sizeof(sTime), true);
    menu.SetTitle("%T\n ", "ReportInfoTitle", client, report.id, report.reporterName, report.targetName, trackName, gS_StyleStrings[report.style], sTime, report.reason);
    menu.AddItem("View", "View Replay", Shavit_IsReplayDataLoaded(report.style, report.track) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

    char line[64];
    Format(line, sizeof(line), "%T", "ReportMenuAccept", client);
    menu.AddItem("Accept", line);

    Format(line, sizeof(line), "%T", "ReportMenuReject", client);
    menu.AddItem("Reject", line);
    menu.Display(client, MENU_TIME_FOREVER);
}

void OpenReportAcceptMenu(int client) {
    Menu menu = new Menu(MenuHandler_ReportAction);
    menu.SetTitle("Accepting Report #%d\nWhat action should be taken?", gI_ActiveReport[client]);
    menu.AddItem("Delete", "Delete the record.");
    menu.AddItem("Ban", "Delete and ban the player.", CheckCommandAccess(client, "sm_ban", ADMFLAG_BAN) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    menu.AddItem("Wipe", "Delete, ban, and wipe the player's records.", CheckCommandAccess(client, "sm_wipeplayer", ADMFLAG_RCON) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    menu.Display(client, 120);
}

void OpenReportRejectMenu(int client) {
    Menu menu = new Menu(MenuHandler_ReportAction);
    menu.SetTitle("Rejecting Report #%d\nWhat action should be taken?", gI_ActiveReport[client]);
    menu.AddItem("RejectReport", "Reject the report.");
    menu.AddItem("Blacklist", "Reject and blacklist the reporter.", CheckCommandAccess(client, "sm_kick", ADMFLAG_KICK) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    menu.AddItem("Blackban", "Reject and ban the reporter.", CheckCommandAccess(client, "sm_ban", ADMFLAG_BAN) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    menu.Display(client, 120);
}

void OpenReportTrackMenu(int client) {
    Menu menu = new Menu(MenuHandler_ReportTrack);
    menu.SetTitle("%T\n ", "ReportTrackTitle", client);
    int validTrack = -1;
    for (int i = 0; i < TRACKS_SIZE; i++) {
        bool records = false;

        for (int j = 0; j < gI_Styles; j++) {
            if (Shavit_GetWorldRecord(j, i) > 0.0) {
                records = true;
                break;
            }
        }
        if (!records)
            continue;
        validTrack = i;
        char sInfo[8];
        IntToString(i, sInfo, 8);
        char sTrack[32];
        GetTrackName(client, i, sTrack, 32);
        menu.AddItem(sInfo, sTrack, ITEMDRAW_DEFAULT);
    }

    if (menu.ItemCount == 0) {
        delete menu;
        Shavit_PrintToChat(client, "%T", "NoRecords", client, gS_ChatStrings.sWarning, gS_ChatStrings.sText);
        return;
    } else if (menu.ItemCount == 1) {
        delete menu;
        gI_MenuTrack[client] = validTrack;
        OpenReportStyleMenu(client, validTrack);
        return;
    }
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

void OpenReportStyleMenu(int client, int track) {
    char sTrack[32];
    GetTrackName(client, track, sTrack, 32);

    Menu menu = new Menu(MenuHandler_ReplayStyle);
    menu.SetTitle("%T (%s)\n ", "ReportStyleTitle", client, sTrack);

    int[] styles = new int[gI_Styles];
    Shavit_GetOrderedStyles(styles, gI_Styles);

    int valid = -1;
    for (int i = 0; i < gI_Styles; i++) {
        int iStyle = styles[i];
        char sInfo[8];
        IntToString(iStyle, sInfo, 8);

        float time = Shavit_GetWorldRecord(iStyle, track);
        if (time <= 0)
            continue;
        valid = iStyle;
        char sDisplay[64];
        char sTime[32];
        FormatSeconds(time, sTime, 32, false);
        FormatEx(sDisplay, 64, "%s - %s", gS_StyleStrings[iStyle].sStyleName, sTime);
        menu.AddItem(sInfo, sDisplay, ITEMDRAW_DEFAULT);
    }

    if (menu.ItemCount == 0) {
        Shavit_PrintToChat(client, "%T", "UnknownError", client, gS_ChatStrings.sWarning, "Shavit-0", gS_ChatStrings.sText);
        delete menu;
    } else if (menu.ItemCount == 1) {
        gI_MenuStyle[client] = valid;
        FakeClientCommand(client, "sm_report %d %d", track, valid);
        delete menu;
        return;
    }

    menu.Display(client, 60);
}

void OpenReportReasonMenu(int client) {
    Menu menu = new Menu(MenuHandler_ReportReason);
    menu.SetTitle("%T\n ", "ReportReasonTitle", client);
    for (int i = 0; i < sizeof(gS_Reasons); i++) {
        char sInfo[sizeof(gS_Reasons[])];
        IntToString(i, sInfo, sizeof(sInfo));
        menu.AddItem(sInfo, gS_Reasons[i], ITEMDRAW_DEFAULT);
    }
    menu.Display(client, 60);
}

void OpenReportAuditMenu(int client, report_t report) {
    gH_Auditing[client] = report;
    Menu menu           = CreateMenu(MenuHandler_ReportAudit);
    char trackName[32], sTime[32];
    GetTrackName(client, report.track, trackName, sizeof(trackName));
    FormatSeconds(report.time, sTime, sizeof(sTime), true);
    menu.SetTitle("%T\n ", "ReportAuditTitle",
      client, report.id, report.reporterName, report.targetName, trackName,
      gS_StyleStrings[report.style], sTime, report.reason, view_as<int>(report.resolution) == -1 ? "N/A" : report.handlerName,
      view_as<int>(report.resolution) == -1 ? "N/A" : gS_Resolutions[report.resolution]);
    menu.AddItem("Delete", "Delete Report");
    switch (report.resolution) {
        case BLACKLIST:
            menu.AddItem("Unblacklist", "Remove Blacklist");
        case BLACKBAN: {
            char line[64];
            Format(line, sizeof(line), "Unban %s", report.reporterName);
            menu.AddItem("Unblackban", line);
        }
        case BAN: {
            char line[64];
            Format(line, sizeof(line), "Unban %s", report.targetName);
            menu.AddItem("Unban", line);
        }
    }
    menu.Display(client, 300);
}

//
// Menu Handlers
//

int MenuHandler_ReportView(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_End) {
        delete menu;
        return 0;
    }
    if (action != MenuAction_Select)
        return 0;
    FakeClientCommand(param1, "sm_reports %d", param2);
    return 0;
}

int MenuHandler_ReportAction(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_End || action == MenuAction_Cancel) {
        if (action == MenuAction_Cancel && param2 == MenuCancel_Exit)
            FakeClientCommand(param1, "sm_reports");
        if (param1 >= 0 && param1 < sizeof(gI_ActiveReport))
            gI_ActiveReport[param1] = -1;
        if (action == MenuAction_End)
            delete menu;
        return 0;
    }
    if (gI_ActiveReport[param1] == -1) {
        Shavit_PrintToChat(param1, "%T", "UnknownError", param1, gS_ChatStrings.sWarning, "Invalid gI_ActiveReport value", gS_ChatStrings.sText);
        delete menu;
        return 0;
    }
    char line[16];
    GetMenuItem(menu, param2, line, sizeof(line));
    report_t report;
    gH_Reports.GetArray(gI_ActiveReport[param1], report);
    if (StrEqual(line, "View")) {
        Shavit_StartReplay(report.style, report.track, -1.0, param1, Replay_Dynamic, Replay_Dynamic, true);
        FakeClientCommand(param1, "sm_reports %d", gI_ActiveReport[param1]);
        return 0;
    } else if (StrEqual(line, "Accept")) {
        OpenReportAcceptMenu(param1);
    } else if (StrEqual(line, "Reject")) {
        OpenReportRejectMenu(param1);
    } else if (StrEqual(line, "Delete")) {
        SQL_ResolveReport(param1, DELETE);
    } else if (StrEqual(line, "Ban")) {
        SQL_ResolveReport(param1, BAN);
    } else if (StrEqual(line, "Wipe")) {
        SQL_ResolveReport(param1, WIPE);
    } else if (StrEqual(line, "RejectReport")) {
        SQL_ResolveReport(param1, REJECT);
    } else if (StrEqual(line, "Blacklist")) {
        SQL_ResolveReport(param1, BLACKLIST);
    } else if (StrEqual(line, "Blackban")) {
        SQL_ResolveReport(param1, BLACKBAN);
    } else
        Shavit_PrintToChat(param1, "%T", "UnknownError", param1, gS_ChatStrings.sWarning, "Invalid MenuItem", gS_ChatStrings.sText);

    return 0;
}

int MenuHandler_ReportAudit(Menu menu, MenuAction action, int param1, int param2) {
    if (action != MenuAction_Select) {
        if (action == MenuAction_End)
            delete menu;
        return 0;
    }
    report_t report;
    report = gH_Auditing[param1];
    char item[64];
    GetMenuItem(menu, param2, item, sizeof(item));
    if (StrEqual(item, "Unban")) {
        Shavit_PrintToChat(param1, "%T", "ReportAuditUnban", param1, gS_ChatStrings.sVariable, report.id, gS_ChatStrings.sText, gS_ChatStrings.sWarning, report.targetName, gS_ChatStrings.sText);
        char sid[MAX_AUTHID_LENGTH], reason[64], sId[8];
        gCS_BanReason.GetString(reason, sizeof(reason));
        IntToString(report.id, sId, sizeof(sId));
        ReplaceString(reason, sizeof(reason), "{id}", sId);
        AccountIDToSteamID64(report.reported, sid, sizeof(sid));
        FakeClientCommand(param1, "sm_unban %s", sid);
    } else if (StrEqual(item, "Unblackban")) {
        char sid[MAX_AUTHID_LENGTH], reason[64], sId[8];
        gCS_BlacklistReason.GetString(reason, sizeof(reason));
        IntToString(report.id, sId, sizeof(sId));
        ReplaceString(reason, sizeof(reason), "{id}", sId);
        AccountIDToSteamID64(report.reporter, sid, sizeof(sid));
        FakeClientCommand(param1, "sm_unban %s", sid);
        Shavit_PrintToChat(param1, "%T", "ReportAuditUnblackban", param1, gS_ChatStrings.sVariable, report.id, gS_ChatStrings.sText, gS_ChatStrings.sWarning, report.reporterName, gS_ChatStrings.sText);
    } else if (StrEqual(item, "Unblacklist")) {
        Shavit_PrintToChat(param1, "%T", "ReportAuditWhitelist", param1, gS_ChatStrings.sVariable, report.id, gS_ChatStrings.sText, gS_ChatStrings.sWarning, report.reporterName, gS_ChatStrings.sText);
        report.resolution = REJECT;
        char sQuery[256];
        Format(sQuery, sizeof(sQuery), "UPDATE `%sreports` SET `resolution` = %d WHERE `id` = '%d'", gS_SQLPrefix, view_as<int>(REJECT), report.id);
        QueryLog(gH_SQL, SQL_Void, sQuery);
        for (int i = 1; i <= MaxClients; i++) {
            if (gI_Blacklist[i] == report.id)
                SQL_CheckBlacklist(i);
        }
    } else if (StrEqual(item, "Delete")) {
        Shavit_PrintToChat(param1, "%T", "ReportAuditDelete", param1, gS_ChatStrings.sVariable, report.id, gS_ChatStrings.sText);
        char sQuery[256];
        Format(sQuery, sizeof(sQuery), "DELETE FROM `%sreports` WHERE `id` = '%d'", gS_SQLPrefix, report.id);
        QueryLog(gH_SQL, SQL_Void, sQuery);
        report_t empty;
        gH_Auditing[param1] = empty;
        int active          = -1;
        for (int i = 0; i < gH_Reports.Length; i++) {
            report_t rep;
            gH_Reports.GetArray(i, rep);
            if (rep.id == report.id) {
                active = i;
                break;
            }
        }
        if (active == -1)
            return 0;
        gH_Reports.Erase(active);
        for (int i = 1; i <= MaxClients; i++) {
            int act = gI_ActiveReport[i];
            if (act == active)
                gI_ActiveReport[i] = -1;
            if (act > active)
                gI_ActiveReport[i]--;
        }
    } else
        Shavit_PrintToChat(param1, "%T", "UnknownError", param1, gS_ChatStrings.sWarning, "Invalid MenuItem", gS_ChatStrings.sText);
    return 0;
}

int MenuHandler_ReportTrack(Menu menu, MenuAction action, int param1, int param2) {
    if (action != MenuAction_Select) {
        if (action == MenuAction_End)
            delete menu;
        return 0;
    }
    char sInfo[8];
    menu.GetItem(param2, sInfo, 8);
    int track = StringToInt(sInfo);

    if (track < 0 || track >= TRACKS_SIZE) {
        Shavit_PrintToChat(param1, "%T", "UnknownError", param1, gS_ChatStrings.sWarning, "Invalid track", gS_ChatStrings.sText);
        return 0;
    }

    gI_MenuTrack[param1] = track;
    FakeClientCommand(param1, "sm_report %d", track);
    return 0;
}

int MenuHandler_ReportReason(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_End || action == MenuAction_Cancel) {
        delete menu;
        return 0;
    }
    if (param2 == sizeof(gS_Reasons) - 1) {
        gB_Chat[param1] = true;
        Shavit_PrintToChat(param1, "%T", "PendingReason", param1);
        return 0;
    }
    FakeClientCommand(param1, "sm_report %d %d %s", gI_MenuTrack[param1], gI_MenuStyle[param1], gS_Reasons[param2]);
    return 0;
}

int MenuHandler_ReplayStyle(Menu menu, MenuAction action, int param1, int param2) {
    if (action != MenuAction_Select) {
        if (action == MenuAction_End)
            delete menu;
        return 0;
    }

    char sInfo[16];
    menu.GetItem(param2, sInfo, 16);

    int style = StringToInt(sInfo);

    if (style < 0 || style >= gI_Styles)
        return 0;

    gI_MenuStyle[param1] = style;
    FakeClientCommand(param1, "sm_report %d %d", gI_MenuTrack[param1], style);
    return 0;
}

int MenuHandler_ReportStats(Menu menu, MenuAction action, int param1, int param2) {
    if (action != MenuAction_Select) {
        if (action == MenuAction_End)
            delete menu;
        return 0;
    }
    char sInfo[16], sTitle[32];
    menu.GetItem(param2, sInfo, sizeof(sInfo), _, sTitle, sizeof(sTitle));

    char sQuery[1024];
    DataPack data = new DataPack();
    data.WriteCell(param1);
    data.WriteString(sTitle);
    if (StrEqual(sInfo, "reporters")) {
        FormatEx(sQuery, sizeof(sQuery),
          "SELECT usr.name, COUNT(*) FROM `reports` LEFT JOIN `users` AS usr ON (usr.auth = reports.reporter) GROUP BY `reporter` ORDER BY COUNT(*) DESC LIMIT 50;", gS_SQLPrefix);
        QueryLog(gH_SQL, SQL_LoadStringInt, sQuery, data);
    } else if (StrEqual(sInfo, "reported")) {
        FormatEx(sQuery, sizeof(sQuery),
          "SELECT usr.name, COUNT(*) FROM `%sreports` LEFT JOIN `%splayertimes` AS pt ON (pt.id = recordId) LEFT JOIN `%susers` AS usr ON (usr.auth = pt.auth) GROUP BY pt.auth ORDER BY COUNT(*) DESC LIMIT 50;",
          gS_SQLPrefix, gS_SQLPrefix, gS_SQLPrefix);
        QueryLog(gH_SQL, SQL_LoadStringInt, sQuery, data);
    } else if (StrEqual(sInfo, "accuracy")) {
        FormatEx(sQuery, sizeof(sQuery),
          "SELECT usr.name,\
            COUNT(CASE WHEN `resolution` = '-1' THEN 1 ELSE NULL END) AS '-1',	\
            COUNT(CASE WHEN `resolution` = '0' THEN 1 ELSE NULL END) AS '0',	\
            COUNT(CASE WHEN `resolution` = '1' THEN 1 ELSE NULL END) AS '1',	\
            COUNT(CASE WHEN `resolution` = '2' THEN 1 ELSE NULL END) AS '2',	\
            COUNT(CASE WHEN `resolution` = '3' THEN 1 ELSE NULL END) AS '3',	\
            COUNT(CASE WHEN `resolution` = '4' THEN 1 ELSE NULL END) AS '4',\
            COUNT(CASE WHEN `resolution` = '5' THEN 1 ELSE NULL END) AS '5',\
	        COUNT(CASE WHEN `resolution` < 3 AND `resolution` >= 0 THEN 1 ELSE NULL END) AS 'Accepted', \
            COUNT(*)\
            FROM `reports` LEFT JOIN `users` AS usr ON (reports.reporter = usr.auth) GROUP BY `reporter` ORDER BY `Accepted` DESC;");
        QueryLog(gH_SQL, SQL_LoadAccuracy, sQuery, data);
    } else if (StrEqual(sInfo, "handlers")) {
        FormatEx(sQuery, sizeof(sQuery),
          "SELECT usr.name, COUNT(*) FROM `reports` LEFT JOIN `users` AS usr ON (usr.auth = reports.handler) WHERE `handler` IS NOT NULL GROUP BY `handler` ORDER BY COUNT(*) DESC LIMIT 50;", gS_SQLPrefix);
        QueryLog(gH_SQL, SQL_LoadStringInt, sQuery, data);
    } else if (StrEqual(sInfo, "maps")) {
        FormatEx(sQuery, sizeof(sQuery),
          "SELECT `record`.`map`, COUNT(*) FROM `%sreports` LEFT JOIN `%splayertimes` AS record ON (record.id = reports.recordId) GROUP BY(`record`.`map`) ORDER BY COUNT(*) DESC LIMIT 50;",
          gS_SQLPrefix, gS_SQLPrefix);
        QueryLog(gH_SQL, SQL_LoadStringInt, sQuery, data);
    } else if (StrEqual(sInfo, "resolutions")) {
        FormatEx(sQuery, sizeof(sQuery),
          "SELECT `resolution`, COUNT(*) FROM `%sreports` GROUP BY `resolution` ORDER BY COUNT(*) DESC;", gS_SQLPrefix);
        QueryLog(gH_SQL, SQL_LoadResolutions, sQuery, data);
    }
    return 0;
}

void SQL_LoadAccuracy(Database db, DBResultSet results, const char[] error, DataPack data) {
    if (results == null) {
        LogError("SQL error! Reason: %s", error);
        return;
    }
    data.Reset();
    char title[32];
    int client = data.ReadCell();
    data.ReadString(title, sizeof(title));
    delete data;
    Menu menu = new Menu(MenuHandler_ReportStatsAccuracy);
    menu.SetTitle(title);
    // name `-1` `0` `1` `2` `3` `4` `5` Accepted `COUNT(*)`

    while (results.FetchRow()) {
        int ints[7];
        for (int i = 1; i < 8; i++)
            ints[i - 1] = results.FetchInt(i);
        char name[MAX_NAME_LENGTH];
        results.FetchString(0, name, sizeof(name));
        int total      = results.FetchInt(9);
        int accepted   = results.FetchInt(8);
        float accuracy = (total == 0.0) ? 0.0 : (float(accepted) * 100.0 / total);
        char line[64], info[64];
        Format(line, sizeof(line), "%s: %.2f%% (%d/%d)", name, accuracy, accepted, total);
        Format(info, sizeof(info), "%d;%d;%d;%d;%d;%d;%d", ints[0], ints[1], ints[2], ints[3], ints[4], ints[5], ints[6]);
        menu.AddItem(info, line, ITEMDRAW_DEFAULT);
    }
    menu.Display(client, MENU_TIME_FOREVER);
}

int MenuHandler_ReportStatsAccuracy(Menu menu, MenuAction action, int param1, int param2) {
    if (action != MenuAction_Select) {
        if (action == MenuAction_End) {
            delete menu;
            return 0;
        }
        if (param2 == MenuCancel_Exit) {
            SQL_FetchReportStats(param1);
            return 0;
        }
    }
    Menu newMenu = new Menu(MenuHandler_ReportStatsGeneric);
    char info[64];
    GetMenuItem(menu, param2, info, sizeof(info));
    char sInf[7][4];
    ExplodeString(info, ";", sInf, sizeof(sInf), sizeof(sInf[]));
    int[] ints = new int[sizeof(sInf)];
    char line[32];
    for (int i = 0; i < sizeof(sInf); i++) {
        ints[i] = StringToInt(sInf[i]);
        Format(line, sizeof(line), "%s: %d", i == 0 ? "Unhandled" : gS_Resolutions[i - 1], ints[i]);
        newMenu.AddItem("", line, ITEMDRAW_DISABLED);
    }
    newMenu.Display(param1, MENU_TIME_FOREVER);
    return 0;
}

int MenuHandler_ReportStatsGeneric(Menu menu, MenuAction action, int param1, int param2) {
    if (action != MenuAction_Select) {
        if (action == MenuAction_End) {
            delete menu;
            return 0;
        }
    }
    SQL_FetchReportStats(param1);
    return 0;
}

/**
 * Loads the report from the DBResultSet and fills the given buffer
 */
void LoadReport(DBResultSet results, report_t buffer) {
    // id recordId reporter reason `date` handler resolution handledDate Recorder Reporter track `style` HandlerName time
    buffer.id       = results.FetchInt(0);
    buffer.recordId = results.FetchInt(1);
    buffer.reporter = results.FetchInt(2);
    results.FetchString(3, buffer.reason, sizeof(buffer.reason));
    buffer.date        = results.FetchInt(4);
    buffer.handler     = results.FetchInt(5);
    buffer.resolution  = view_as<Resolution>(results.FetchInt(6));
    buffer.handledDate = results.FetchInt(7);
    results.FetchString(8, buffer.targetName, sizeof(buffer.reporterName));
    results.FetchString(9, buffer.reporterName, sizeof(buffer.reporterName));
    buffer.track = results.FetchInt(10);
    buffer.style = results.FetchInt(11);
    results.FetchString(12, buffer.handlerName, sizeof(buffer.handlerName));
    buffer.time = results.FetchFloat(13);
}

void PostWebhook(report_t report) {
    char url[256];
    gCS_WebhookURL.GetString(url, sizeof(url));
    if (strlen(url) == 0 || StrContains(url, "discord.com/api/webhooks/") == -1)
        return;
    char description[256], time[8], track[32], title[128];
    GetConVarString(FindConVar("hostname"), title, sizeof(title));
    char sid[MAX_AUTHID_LENGTH], id[8];
    IntToString(report.id, id, sizeof(id));
    FormatSeconds(report.time, time, sizeof(time), false);
    // GetClientAuthId(report.reporter, AuthId_SteamID64, sid, sizeof(sid));
    AccountIDToSteamID64(report.reporter, sid, sizeof(sid));
    Format(description, sizeof(description),
      "**[%s](http://www.steamcommunity.com/profiles/%s)** reported",
      report.reporterName, sid);
    AccountIDToSteamID64(report.reported, sid, sizeof(sid));
    GetTrackName(LANG_SERVER, report.track, track, sizeof(track));
    Format(description, sizeof(description),
      "%s **[%s](http://www.steamcommunity.com/profiles/%s)'s** %s %s %s record.",
      description, report.targetName, sid, time, gS_StyleStrings[report.style], track);
    DiscordWebHook hook = new DiscordWebHook(url);
    hook.SetUsername("BHop Reports");
    MessageEmbed embed = new MessageEmbed();
    embed.SetColor("10158080");
    embed.SetDescription(description);
    embed.SetTitle(title);
    embed.AddField("Map", gS_MapName, true);
    embed.AddField("Reason", report.reason, true);
    embed.AddField("ID", id, true);
    hook.Embed(embed);
    hook.Send();
    delete hook;
}