# BHop Reports (Shavit)
A reporting system for [Shavit's BHop Timer](https://github.com/shavitush/bhoptimer).

# Installation
### Prerequisites
- [Shavit's BHop Timer](https://github.com/shavitush/bhoptimer)
- MySQL Database _(Other forms untested)_
1. Copy the compiled SMX file(s) from `addons/sourcemod/plugins` into your plugins folder.
2. Copy the `shavit-report.phrases.txt` file from `addons/sourcemod/translations` into your translations folder.
3. Start the server.

# Features
- Menu System to select WRs
- In-game handling of reports with menu assist
- Report auditing
- Report blacklisting

## Commands
- `sm_report <track> <style> <reason`
  - Accessible to all players that are not blacklisted
  - Currently not limited in terms of cooldown / spam
- `sm_reports`
  - Shows all active (non-resolved) reports
  - Accessible to players that have the ADMFLAG_BAN flag
- `sm_audit [id]`*
  - Shows the specified report and its details
  - Allows admins to override previous resolutions
  - Accessible to players that have the ADMFLAG_CHEAT flag
  - \*Currently in development