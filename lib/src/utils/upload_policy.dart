/// Dartus only creates deletable blobs. Keep the check at public upload
/// boundaries and transaction builders so a rejected option never costs WAL.
void requireDeletableUpload(bool? deletable) {
  if (deletable == false) {
    throw ArgumentError.value(
      deletable,
      'deletable',
      'Dartus uploads must be deletable; omit this option or pass true',
    );
  }
}
