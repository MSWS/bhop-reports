enum Resolution {
  DELETE, BAN, WIPE, REJECT, BLACKLIST, BLACKBAN
}

char gS_Resolutions[][] = {
  "Deleted Record",
  "Banned User",
  "Wiped Data",
  "Rejected",
  "Blacklisted Reporter",
  "Banned Reporter"
};

enum struct report_t {
  int id;
  int recordId;
  int reporter;
  int reported;
  int track;
  int style;
  char reporterName[MAX_NAME_LENGTH];
  char targetName[MAX_NAME_LENGTH];
  char handlerName[MAX_NAME_LENGTH];
  char reason[128];
  int date;
  int handler;
  Resolution resolution;
  int handledDate;
  float time;
}