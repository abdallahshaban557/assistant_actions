/// Spotlight attribute annotations for `@AssistantEntity` fields and getters.
library;

/// Marks a `List<String>` (or `List<String>?`) field or getter on an
/// `@AssistantEntity` whose words become `CSSearchableItemAttributeSet.keywords`
/// in CoreSpotlight.
class EntityKeywords {
  const EntityKeywords();
}

/// Marks a `String` (or `String?`) field or getter on an `@AssistantEntity`
/// whose text becomes `CSSearchableItemAttributeSet.textContent` in
/// CoreSpotlight.
class EntityBody {
  const EntityBody();
}

/// Marks a `DateTime` (or `DateTime?`) field or getter on an
/// `@AssistantEntity` that becomes
/// `CSSearchableItemAttributeSet.contentCreationDate` in CoreSpotlight.
class EntityCreatedAt {
  const EntityCreatedAt();
}

/// Marks a `DateTime` (or `DateTime?`) field or getter on an
/// `@AssistantEntity` that becomes
/// `CSSearchableItemAttributeSet.contentModificationDate` in CoreSpotlight.
class EntityUpdatedAt {
  const EntityUpdatedAt();
}
