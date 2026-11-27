#include "CSQLite.h"

int agents_sqlite_disable_triggers(sqlite3 *database) {
  return sqlite3_db_config(database, SQLITE_DBCONFIG_ENABLE_TRIGGER, 0, (int *)0);
}
