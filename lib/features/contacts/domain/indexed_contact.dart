/// Contact data is session-local and is never persisted by this model.
class IndexedContact {
  const IndexedContact({
    required this.name,
    required this.phone,
  });

  final String name;
  final String phone;
}
