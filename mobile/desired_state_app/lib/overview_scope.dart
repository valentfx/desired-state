/// Returns a single named participant snapshot for personal browsing.
/// Mixed, unknown and unassigned sessions belong only in the collection view.
/// These labels are not stable user IDs and must not be treated as such.
String? overviewParticipant(Map<String, dynamic> manifest) {
  final assignments = manifest['assignments'];
  if (assignments is! Map || assignments.isEmpty) return null;
  if (assignments.values.any((value) => value is! String)) return null;
  final users = assignments.values.cast<String>().toSet();
  if (users.length != 1) return null;
  final user = users.single;
  if (user.trim().isEmpty || user.trim().toLowerCase() == 'unassigned') {
    return null;
  }
  return user;
}
