enum struct report_t
{
  int id;
  int recordId;
  int reporter;
  int reported;
  int track;
  int style;
  char reporterName[MAX_NAME_LENGTH];
  char targetName[MAX_NAME_LENGTH];
  char reason[128];
  int date;
  int handler;
  int resolution;
  int handledDate;
}