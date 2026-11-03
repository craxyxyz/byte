import 'smb_source.dart';

// Byte © 2026 Apurba Laskar. Browsers can't open SMB shares (no raw network sockets).
Future<SmbBackend> connectSmb(String host, String user, String pass, String domain) async =>
    throw const SmbProblem('SMB shares work in the phone app. A browser can\'t reach them.');
