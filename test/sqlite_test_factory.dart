// Real host SQLite for tests only. No native asset hooks/binaries in the app.
import 'dart:ffi';
import 'dart:io';
import 'package:sqlite3/open.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void _initializeSystemSqlite() {
  sqfliteFfiInit();
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () {
      try {
        return DynamicLibrary.open('libsqlite3.so');
      } on ArgumentError {
        // Runtime-only Linux images need not have the development symlink.
        return DynamicLibrary.open('libsqlite3.so.0');
      }
    });
  }
}

final sqliteTestFactory = createDatabaseFactoryFfi(
  ffiInit: _initializeSystemSqlite,
);
