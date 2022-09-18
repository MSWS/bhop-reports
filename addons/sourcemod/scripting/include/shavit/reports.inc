enum struct report_t
{
  int id;
  int recordId;
  int reporter;
  int reported;
  char reporterName[MAX_NAME_LENGTH];
  char targetName[MAX_NAME_LENGTH];
  char reason[128];
}