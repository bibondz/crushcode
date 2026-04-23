#ifndef ZIG_SQLITE_HELPERS_H
#define ZIG_SQLITE_HELPERS_H

#include "sqlite3.h"

/**
 * Wrapper for sqlite3_bind_text that hardcodes SQLITE_TRANSIENT.
 *
 * Zig cannot represent SQLITE_TRANSIENT ((void(*)(void*))-1) at comptime
 * because @ptrFromInt rejects unaligned addresses and @bitCast refuses
 * function-pointer destinations. The C compiler handles this cast natively.
 */
int zig_sqlite3_bind_text_transient(sqlite3_stmt *stmt, int idx,
                                    const char *text, int n);

#endif
