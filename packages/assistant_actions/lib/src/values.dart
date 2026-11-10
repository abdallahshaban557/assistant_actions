/// Values of App Schema types with no Dart equivalent: people, places, files,
/// recurrence rules and unions. Siri's values arrive as these, and entity
/// fields of these types are published as them.
library;

/// A person (`IntentPerson`), such as a message's author or an event's
/// organizer.
class AssistantPerson {
  const AssistantPerson({this.name, this.email, this.phone, this.id, this.isMe = false});

  factory AssistantPerson.fromJson(Map<String, Object?> json) => AssistantPerson(
        name: json['name'] as String?,
        email: json['email'] as String?,
        phone: json['phone'] as String?,
        id: json['id'] as String?,
        isMe: json['isMe'] == true,
      );

  /// The display name.
  final String? name;
  final String? email;
  final String? phone;

  /// A Contacts identifier, or the app's own id for the person.
  final String? id;

  /// The device's owner.
  final bool isMe;

  Map<String, Object?> toJson() => {
        if (name != null) 'name': name,
        if (email != null) 'email': email,
        if (phone != null) 'phone': phone,
        if (id != null) 'id': id,
        if (isMe) 'isMe': true,
      };

  @override
  bool operator ==(Object other) =>
      other is AssistantPerson &&
      other.name == name &&
      other.email == email &&
      other.phone == phone &&
      other.id == id &&
      other.isMe == isMe;

  @override
  int get hashCode => Object.hash(name, email, phone, id, isMe);

  @override
  String toString() => 'AssistantPerson(${name ?? email ?? phone ?? id ?? ''})';
}

/// A place (`PlaceDescriptor`): a coordinate, an address, or both, with an
/// optional name.
class AssistantPlace {
  const AssistantPlace({this.name, this.address, this.latitude, this.longitude});

  factory AssistantPlace.fromJson(Map<String, Object?> json) => AssistantPlace(
        name: json['name'] as String?,
        address: json['address'] as String?,
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
      );

  final String? name;
  final String? address;
  final double? latitude;
  final double? longitude;

  Map<String, Object?> toJson() => {
        if (name != null) 'name': name,
        if (address != null) 'address': address,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
      };

  @override
  bool operator ==(Object other) =>
      other is AssistantPlace &&
      other.name == name &&
      other.address == address &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(name, address, latitude, longitude);

  @override
  String toString() => 'AssistantPlace(${name ?? address ?? '$latitude,$longitude'})';
}

/// A file (`IntentFile`). Files Siri gives the app are copied into its
/// Application Support folder (`assistant_actions/files/`), so [path] stays
/// readable until the app deletes it, even for calls queued while it wasn't
/// running.
class AssistantFile {
  const AssistantFile({required this.path, this.name, this.type});

  factory AssistantFile.fromJson(Map<String, Object?> json) =>
      AssistantFile(path: json['path'] as String, name: json['name'] as String?, type: json['type'] as String?);

  /// An absolute file path.
  final String path;

  /// The file name Siri gave, such as `IMG_0042.HEIC`.
  final String? name;

  /// Its uniform type identifier, such as `public.jpeg`.
  final String? type;

  Map<String, Object?> toJson() => {'path': path, if (name != null) 'name': name, if (type != null) 'type': type};

  @override
  bool operator ==(Object other) => other is AssistantFile && other.path == path && other.name == name && other.type == type;

  @override
  int get hashCode => Object.hash(path, name, type);

  @override
  String toString() => 'AssistantFile($path)';
}

/// What Visual Intelligence saw (`SemanticContentDescriptor`): the labels it
/// recognised, such as `dog` or `golden retriever`, and the image itself.
///
/// The image is written as a PNG into the app's Application Support folder
/// (`assistant_actions/files/`), like files Siri passes; delete it when done.
class AssistantSemanticContent {
  const AssistantSemanticContent({this.labels = const [], this.image});

  factory AssistantSemanticContent.fromJson(Map<String, Object?> json) => AssistantSemanticContent(
        labels: [for (final l in (json['labels'] as List?) ?? const []) if (l is String) l],
        image: json['image'] is Map && (json['image'] as Map)['path'] is String
            ? AssistantFile.fromJson((json['image'] as Map).cast())
            : null,
      );

  final List<String> labels;

  /// The camera frame or screenshot region, when Visual Intelligence gave one.
  final AssistantFile? image;

  Map<String, Object?> toJson() => {'labels': labels, if (image != null) 'image': image!.toJson()};

  @override
  bool operator ==(Object other) =>
      other is AssistantSemanticContent && _deepEquals(other.labels, labels) && other.image == image;

  @override
  int get hashCode => Object.hash(Object.hashAll(labels), image);

  @override
  String toString() => 'AssistantSemanticContent(${labels.join(', ')}${image == null ? '' : ', ${image!.path}'})';
}

/// A recurrence rule (`Calendar.RecurrenceRule`), as Foundation encodes it.
/// Pass one Siri gave back unchanged to keep it, or read [frequency] and
/// [interval].
class AssistantRecurrence {
  const AssistantRecurrence(this.json);

  /// Foundation's `Codable` form of the rule.
  final Map<String, Object?> json;

  /// `daily`, `weekly`, `monthly`, `yearly`, … .
  String? get frequency => json['frequency'] as String?;

  /// Every [interval] periods; 1 when absent.
  int get interval => (json['interval'] as num?)?.toInt() ?? 1;

  @override
  bool operator ==(Object other) => other is AssistantRecurrence && _deepEquals(other.json, json);

  @override
  int get hashCode => Object.hashAll(json.keys);

  @override
  String toString() => 'AssistantRecurrence($json)';
}

/// One case of a schema union, such as a calendar event location that is a
/// place or an address: [caseName] is the case (`place`), [value] its value
/// as a Dart value (`AssistantPlace`, `String`, `DateTime`, an entity id, …).
class AssistantUnion {
  const AssistantUnion(this.caseName, this.value);

  final String caseName;
  final Object? value;

  @override
  bool operator ==(Object other) => other is AssistantUnion && other.caseName == caseName && other.value == value;

  @override
  int get hashCode => Object.hash(caseName, value);

  @override
  String toString() => 'AssistantUnion($caseName: $value)';
}

bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length && a.keys.every((k) => b.containsKey(k) && _deepEquals(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
