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

#pragma newdecls required
#pragma semicolon 1

Database gH_SQL = null;

// table prefix
char gS_MySQLPrefix[32];

// cache
ArrayList gH_Reports;
char gS_MapName[PLATFORM_MAX_PATH];
int gI_MenuTrack[MAXPLAYERS + 1];
int gI_MenuStyle[MAXPLAYERS + 1];
int gI_Styles;
stylestrings_t gS_StyleStrings[STYLE_LIMIT];
chatstrings_t gS_ChatStrings;
bool gB_Late = false;

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

    RegConsoleCmd("sm_report", Command_Report, "Report a player's record");

    GetTimerSQLPrefix(gS_MySQLPrefix, sizeof(gS_MySQLPrefix));
    gH_SQL = GetTimerDatabaseHandle();

    if (gB_Late) {
        Shavit_OnStyleConfigLoaded(Shavit_GetStyleCount());
        Shavit_OnChatConfigLoaded();
    }

    char sQuery[512];
    FormatEx(sQuery, sizeof(sQuery),
      "CREATE TABLE IF NOT EXISTS `%sreports` (`id` INT AUTO_INCREMENT NOT NULL, `recordId` INT NOT NULL, `reporter` INT NOT NULL, `reason` VARCHAR(128) NOT NULL, PRIMARY KEY (`id`), FOREIGN KEY (`recordId`) REFERENCES %splayertimes(`id`) ON DELETE CASCADE);",
      gS_MySQLPrefix, gS_MySQLPrefix);
    QueryLog(gH_SQL, SQL_Void, sQuery);
}

public void OnMapStart() {
    GetCurrentMap(gS_MapName, sizeof(gS_MapName));
    LoadReports();
}

public void Shavit_OnStyleConfigLoaded(int styles) {
    for (int i = 0; i < styles; i++)
        Shavit_GetStyleStringsStruct(i, gS_StyleStrings[i]);
    gI_Styles = styles;
}

public void Shavit_OnChatConfigLoaded() {
    Shavit_GetChatStringsStruct(gS_ChatStrings);
}

public void LoadReports() {
    char sQuery[512];
    FormatEx(sQuery, sizeof(sQuery), "SELECT `report`.*, `clients`.`name` AS 'Recorder', `reportClient`.`name` AS 'Reporter' FROM `playertimes` AS times INNER JOIN `reports` AS report ON (report.recordId=times.id) INNER JOIN `users` AS clients ON (times.auth = clients.auth) LEFT JOIN `users` AS reportClient ON (report.reporter=reportClient.auth) WHERE `map` = '%';", gS_MapName);
    QueryLog(gH_SQL, SQL_LoadedReports, sQuery);
}

public Action Command_Reports(int client, int args) {
    return Plugin_Handled;
}

public Action Command_Report(int client, int args) {
    // sm_report [track] [style]
    if (args == 0) {
        OpenReportTrackMenu(client);
    } else if (args != 2)
        return Plugin_Handled;

    char sArgs[2][8];
    GetCmdArg(1, sArgs[0], sizeof(sArgs[]));
    GetCmdArg(2, sArgs[1], sizeof(sArgs[]));
    int track = StringToInt(sArgs[0]), style = StringToInt(sArgs[1]), recordId;
    Shavit_GetWRRecordID(style, recordId, track);
    if (recordId == -1) {
        Shavit_PrintToChat(client, "%T", "UnknownRecord", client, gS_ChatStrings.sWarning, gS_ChatStrings.sText);
        return Plugin_Handled;
    }
    Shavit_PrintToChat(client, "Record ID: %d", recordId);
    return Plugin_Handled;
}

void OpenReportTrackMenu(int client) {
    Menu menu = new Menu(MenuHandler_ReportTrack);
    menu.SetTitle("%T\n ", "CentralReportTrack", client);
    for (int i = 0; i < TRACKS_SIZE; i++) {
        bool records = false;

        for (int j = 0; j < gI_Styles; j++) {
            if (Shavit_GetWorldRecord(j, i) > 0.0) {
                records = true;
                break;
            }
        }
        char sInfo[8];
        IntToString(i, sInfo, 8);
        char sTrack[32];
        GetTrackName(client, i, sTrack, 32);
        menu.AddItem(sInfo, sTrack, (records) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    }

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public void UploadReport(report_t report) {
    char sQuery[512];
    // gH_SQL.Format(report.reason, sizeof(report.reason), report.reason);
    gH_SQL.Escape(report.reason, report.reason, sizeof(report.reason));
    FormatEx(sQuery, sizeof(sQuery), "INSERT INTO `%sreports` (`recordId`, `reporter`, `reason`) VALUES('%d', '%d', '%s'", gS_MySQLPrefix, report.recordId, report.reporter, report.reason);
    QueryLog(gH_SQL, SQL_Void, sQuery);
}

public int MenuHandler_ReportTrack(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_End || action == MenuAction_Cancel) {
        delete menu;
        return 0;
    }
    char sInfo[8];
    menu.GetItem(param2, sInfo, 8);
    int track = StringToInt(sInfo);

    // avoid an exploit
    if (track >= 0 && track < TRACKS_SIZE) {
        gI_MenuTrack[param1] = track;
        OpenReplayStyleMenu(param1, track);
    }
    return 0;
}

void OpenReplayStyleMenu(int client, int track) {
    char sTrack[32];
    GetTrackName(client, track, sTrack, 32);

    Menu menu = new Menu(MenuHandler_ReplayStyle);
    menu.SetTitle("%T (%s)\n ", "CentralReportTitle", client, sTrack);

    int[] styles = new int[gI_Styles];
    Shavit_GetOrderedStyles(styles, gI_Styles);

    for (int i = 0; i < gI_Styles; i++) {
        int iStyle = styles[i];

        char sInfo[8];
        IntToString(iStyle, sInfo, 8);

        float time = Shavit_GetWorldRecord(track, iStyle);

        char sDisplay[64];

        if (time > 0.0) {
            char sTime[32];
            FormatSeconds(time, sTime, 32, false);

            FormatEx(sDisplay, 64, "%s - %s", gS_StyleStrings[iStyle].sStyleName, sTime);
        } else {
            strcopy(sDisplay, 64, gS_StyleStrings[iStyle].sStyleName);
        }

        menu.AddItem(sInfo, sDisplay, (time > 0) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    }

    if (menu.ItemCount == 0) {
        menu.AddItem("-1", "ERROR");
    }

    menu.ExitBackButton = true;
    menu.DisplayAt(client, 0, 300);
}

public int MenuHandler_ReplayStyle(Menu menu, MenuAction action, int param1, int param2) {
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
    return 0;
}

public void SQL_LoadedReports(Database db, DBResultSet results, const char[] error, DataPack hPack) {
    if (results == null) {
        LogError("Timer error! Failed to load report data. Reason: %s", error);
        return;
    }

    while (results.FetchRow()) {
        report_t report;
        report.id       = results.FetchInt(0);
        report.recordId = results.FetchInt(1);
        report.reporter = results.FetchInt(2);
        results.FetchString(3, report.reason, sizeof(report.reason));
        results.FetchString(4, report.targetName, sizeof(report.reporterName));
        results.FetchString(5, report.reporterName, sizeof(report.reporterName));
        gH_Reports.PushArray(report);
    }
}

public void SQL_Void(Database db, DBResultSet results, const char[] error, DataPack hPack) {
    if (results == null) {
        LogError("SQL error! Reason: %s", error);
        return;
    }
}