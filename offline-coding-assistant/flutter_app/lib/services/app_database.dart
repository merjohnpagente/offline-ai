import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// The single local SQLite database used by the app.
///
/// It stores conversations, messages, drafts, attachment metadata, and
/// generation settings. The database lives in the app's private data directory,
/// so it survives normal app restarts and updates. Nothing is uploaded.
class AppDatabase {
  AppDatabase._(this.database);

  static const String fileName = 'offline_ai.db';
  static const int schemaVersion = 1;

  final Database database;

  static Future<AppDatabase> open({String? path}) async {
    final databasePath = path ?? p.join(await getDatabasesPath(), fileName);

    final database = await openDatabase(
      databasePath,
      version: schemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.rawQuery('PRAGMA journal_mode = WAL');
      },
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
    );

    return AppDatabase._(database);
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        draft TEXT NOT NULL DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        seq INTEGER NOT NULL,
        FOREIGN KEY (conversation_id)
          REFERENCES conversations (id)
          ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_conversation
      ON messages (conversation_id, seq)
    ''');

    await db.execute('''
      CREATE INDEX idx_conversations_updated
      ON conversations (updated_at DESC)
    ''');

    // Ready for the attachment/OCR feature. Files are copied into app-private
    // storage and only their metadata and extracted text live in SQLite.
    await db.execute('''
      CREATE TABLE attachments (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        message_id TEXT,
        name TEXT NOT NULL,
        local_path TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        kind TEXT NOT NULL,
        extracted_text TEXT NOT NULL DEFAULT '',
        size_bytes INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (conversation_id)
          REFERENCES conversations (id)
          ON DELETE CASCADE,
        FOREIGN KEY (message_id)
          REFERENCES messages (id)
          ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_attachments_conversation
      ON attachments (conversation_id)
    ''');

    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // Version 1 is the initial schema. Future migrations go here.
  }

  Future<String?> getSetting(String key) async {
    final rows = await database.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    await database.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeSetting(String key) async {
    await database.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  Future<void> clearSettings() async {
    await database.delete('settings');
  }
}
