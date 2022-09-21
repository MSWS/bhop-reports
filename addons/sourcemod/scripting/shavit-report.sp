/*
 * shavit's Timer - Chat
 * by: shavit, Nairda, GAMMA CASE, Kid Fearless, rtldg, BoomShotKapow
 *
 * This file is part of shavit's Timer (https://github.com/shavitush/bhoptimer)
 *
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#include <sourcemod>
#include <shavit/core>
#include <shavit/reports>
#include <shavit/wr>
#include <shavit/replay-playback>
#include <shavit/steamid-stocks>

#pragma newdecls required
#pragma semicolon 1

//
//// Globals
//

Database gH_SQL = null;
ArrayList gH_Reports;
stylestrings_t gS_StyleStrings[STYLE_LIMIT];
chatstrings_t gS_ChatStrings;
ConVar gCS_BanReason;
ConVar gCS_BlacklistReason;
ConVar gCF_BanDuration;
ConVar gCF_BlacklistDuration;
char gS_SQLPrefix[32];
char gS_MapName[PLATFORM_MAX_PATH];
int gI_ActiveReport[MAXPLAYERS + 1];
int gI_MenuTrack[MAXPLAYERS + 1];
int gI_MenuStyle[MAXPLAYERS + 1];
int gI_Styles;
bool gB_Chat[MAXPLAYERS + 1];
bool gB_Late = false;

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
    url         = "https://github.com/shavitush/bhoptimer"
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
    RegConsoleCmd("sm_report", Command_Report, "Report a player's record");

    gCS_BanReason         = CreateConVar("shavit_reports_reason", "#{id} Record Violation", "Report ban reason");
    gCS_BlacklistReason   = CreateConVar("shavit_blacklist_reason", "#{id} Report Violation", "Report blacklist reason");
    gCF_BanDuration       = CreateConVar("shavit_reports_bantime", "40320", "Default ban duration", _, true, -1.0, true, 120960.0);
    gCF_BlacklistDuration = CreateConVar("shavit_blacklist_bantime", "10080", "Default blacklist duration", _, true, -1.0, true, 120960.0);

    AutoExecConfig();
    GetTimerSQLPrefix(gS_SQLPrefix, sizeof(gS_SQLPrefix));
    gH_SQL = GetTimerDatabaseHandle();

    if (gB_Late) {
        Shavit_OnStyleConfigLoaded(Shavit_GetStyleCount());
        Shavit_OnChatConfigLoaded();
    }

    CreateSQL();
}

//
//// Plugin Initialization
//
public void OnMapStart() {
    GetCurrentMap(gS_MapName, sizeof(gS_MapName));
    LoadReports();
}

public Action OnClientSayCommand(int client, const char[] cmd, const char[] args) {
    if (!gB_Chat[client])
        return Plugin_Continue;
    gB_Chat[client] = false;
    FakeClientCommand(client, "sm_report %d %d %s", gI_MenuTrack[client], gI_MenuStyle[client], args);
    return Plugin_Stop;
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

void CreateSQL() {
    char sQuery[512];
    FormatEx(sQuery, sizeof(sQuery),
      "CREATE TABLE IF NOT EXISTS `%sreports` (`id` INT AUTO_INCREMENT NOT NULL, `recordId` INT NOT NULL, `reporter` INT NOT NULL, `reason` VARCHAR(128) NOT NULL, `date` TIMESTAMP NOT NULL DEFAULT NOW(), `handler` INT, `resolution` INT, `handledDate` TIMESTAMP, PRIMARY KEY (`id`), FOREIGN KEY (`reporter`) REFERENCES %susers(`auth`), FOREIGN KEY (`recordId`) REFERENCES %splayertimes(`id`) ON DELETE CASCADE, FOREIGN KEY (`handler`) REFERENCES %susers(`auth`));",
      gS_SQLPrefix, gS_SQLPrefix, gS_SQLPrefix, gS_SQLPrefix);
    QueryLog(gH_SQL, SQL_Void, sQuery);
}

void LoadReports() {
    LogMessage("Loading reports...");
    gH_Reports.Clear();
    char sQuery[512];
    FormatEx(sQuery, sizeof(sQuery), "SELECT `report`.*, `clients`.`name` AS 'Recorder', `reportClient`.`name` AS 'Reporter', `times`.`track` , `times`.`style` FROM `playertimes` AS times INNER JOIN `%sreports` AS report ON (report.recordId=times.id) INNER JOIN `users` AS clients ON (times.auth = clients.auth) LEFT JOIN `users` AS reportClient ON (report.reporter=reportClient.auth) WHERE `handler` IS NULL AND `map` = '%s';", gS_SQLPrefix, gS_MapName);
    QueryLog(gH_SQL, SQL_LoadedReports, sQuery, -1);
}

void SQL_LoadedReports(Database db, DBResultSet results, const char[] error, int reporter = -1) {
    if (results == null) {
        LogError("Timer error! Failed to load report data. Reason: %s", error);
        return;
    }

    while (results.FetchRow()) {
        int id = LoadReport(results);
        if (reporter != -1)
            Shavit_PrintToChat(reporter, "%T", "ReportSubmittedID", reporter, gS_ChatStrings.sVariable, id, gS_ChatStrings.sText);
    }

    if (reporter == -1)
        LogMessage("Loaded %d reports", gH_Reports.Length);
}

void UploadReport(report_t report) {
    char sQuery[512];
    gH_SQL.Escape(report.reason, report.reason, sizeof(report.reason));
    FormatEx(sQuery, sizeof(sQuery), "INSERT INTO `%sreports` (`recordId`, `reporter`, `reason`) VALUES('%d', '%d', '%s');", gS_SQLPrefix, report.recordId, report.reporter, report.reason);
    QueryLog(gH_SQL, SQL_Void, sQuery);
}

void UpdateReport(report_t report, int client = -1) {
    char sQuery[512];
    FormatEx(sQuery, sizeof(sQuery), "SELECT `report`.*, `clients`.`name` AS 'Recorder', `reportClient`.`name` AS 'Reporter', `times`.`track` , `times`.`style` FROM `playertimes` AS times INNER JOIN `%sreports` AS report ON (report.recordId=times.id) INNER JOIN `users` AS clients ON (times.auth = clients.auth) LEFT JOIN `users` AS reportClient ON (report.reporter=reportClient.auth) WHERE `reason` = '%s' AND `reporter` = '%d' ORDER BY `date` DESC LIMIT 1;", gS_SQLPrefix, report.reason, report.reporter);
    QueryLog(gH_SQL, SQL_LoadedReports, sQuery, client);
}

// void DeleteReport(int reportIndex) {
//     report_t report;
//     gH_Reports.GetArray(reportIndex, report);
//     char sQuery[512];
//     FormatEx(sQuery, sizeof(sQuery), "DELETE FROM `%sreports` WHERE `id` = '%d';", gS_SQLPrefix, report.id);
//     QueryLog(gH_SQL, SQL_Void, sQuery);
//     gH_Reports.Erase(reportIndex);
// }

void SQL_Void(Database db, DBResultSet results, const char[] error, DataPack hPack) {
    if (results == null) {
        LogError("SQL error! Reason: %s", error);
        return;
    }
}

void ResolveReport(int client, Resolution resolution) {
    report_t report;
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

    Format(sQuery, sizeof(sQuery),
      "UPDATE `%sreports` SET `handler` = '%d', `resolution` = '%d', `handledDate` = NOW();",
      gS_SQLPrefix, report.handler, view_as<int>(resolution));
    QueryLog(gH_SQL, SQL_Void, sQuery);
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

public Action Command_Report(int client, int args) {
    // sm_report [track] [style] [reason]
    if (args == 0 && IsClientInGame(client)) {
        OpenReportTrackMenu(client);
        return Plugin_Handled;
    }

    char command[200];
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
    UploadReport(report);
    UpdateReport(report, client); // Refetch report data to grab ID
    Shavit_PrintToChat(client, "%T", "ReportSubmitted", client);
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
    FormatSeconds(Shavit_GetWorldRecord(report.style, report.track), sTime, sizeof(sTime), true);
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
        menu.AddItem("-1", "ERROR");
    } else if (menu.ItemCount == 1) {
        gI_MenuStyle[client] = valid;
        FakeClientCommand(client, "sm_report %d %d", track, valid);
        delete menu;
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
        if (action == MenuAction_Cancel && param2 == MenuCancel_Exit) {
            FakeClientCommand(param1, "sm_reports");
        }
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
        ResolveReport(param1, DELETE);
    } else if (StrEqual(line, "Ban")) {
        ResolveReport(param1, BAN);
    } else if (StrEqual(line, "Wipe")) {
        ResolveReport(param1, WIPE);
    } else if (StrEqual(line, "RejectReport")) {
        ResolveReport(param1, WIPE);
    } else if (StrEqual(line, "Blacklist")) {
        ResolveReport(param1, BLACKLIST);
    } else if (StrEqual(line, "Blackban")) {
        ResolveReport(param1, BLACKBAN);
    } else
        Shavit_PrintToChat(param1, "%T", "UnknownError", param1, gS_ChatStrings.sWarning, "Invalid MenuItem", gS_ChatStrings.sText);

    return 0;
}

int MenuHandler_ReportTrack(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_End || action == MenuAction_Cancel) {
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
        // Prompt for chat
        gB_Chat[param1] = true;
        Shavit_PrintToChat(param1, "%T", "PendingReason", param1);
        return 0;
    }
    FakeClientCommand(param1, "sm_report %d %d %s", gI_MenuTrack[param1], gI_MenuStyle[param1], gS_Reasons[param2]);
    return 0;
}

int MenuHandler_ReplayStyle(Menu menu, MenuAction action, int param1, int param2) {
    if (action != MenuAction_Select) {
        if (action == MenuAction_End || action == MenuAction_Cancel)
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

int LoadReport(DBResultSet results) {
    // id recordId reporter reason `date` handler resolution handledDate Recorder Reporter track `style`
    report_t report;
    report.id       = results.FetchInt(0);
    report.recordId = results.FetchInt(1);
    report.reporter = results.FetchInt(2);
    results.FetchString(3, report.reason, sizeof(report.reason));
    report.date        = results.FetchInt(4);
    report.handler     = results.FetchInt(5);
    report.resolution  = results.FetchInt(6);
    report.handledDate = results.FetchInt(7);
    results.FetchString(8, report.targetName, sizeof(report.reporterName));
    results.FetchString(9, report.reporterName, sizeof(report.reporterName));
    report.track = results.FetchInt(10);
    report.style = results.FetchInt(11);
    gH_Reports.PushArray(report);
    return report.id;
}