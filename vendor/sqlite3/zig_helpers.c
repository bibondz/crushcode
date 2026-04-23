#include "zig_helpers.h"

int zig_sqlite3_bind_text_transient(sqlite3_stmt *stmt, int idx,
                                    const char *text, int n) {
    return sqlite3_bind_text(stmt, idx, text, n, SQLITE_TRANSIENT);
}
