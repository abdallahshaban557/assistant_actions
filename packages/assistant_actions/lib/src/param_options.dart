/// Parameter options, conditional Shortcuts summaries, currency amounts and
/// typed Foundation measurements for `@AssistantAction` and `@Param`.
library;

/// How Shortcuts shows a numeric (`int` or `double`) parameter.
enum ParamControlStyle {
  /// Plus and minus buttons (`stepper`, Apple's default).
  stepper,

  /// A text field (`field`).
  field,

  /// A continuous slider (`slider`, `double` parameters only).
  slider,
}

/// How Shortcuts capitalizes text entered into a `String` parameter
/// (`String.IntentInputOptions.CapitalizationType`).
enum TextCapitalizationMode {
  none,
  words,
  sentences,
  allCharacters,
}

/// Which keyboard Shortcuts opens for a `String` parameter
/// (`String.IntentInputOptions.KeyboardType`).
enum ParamKeyboardType {
  defaultType,
  asciiCapable,
  numbersAndPunctuation,
  url,
  numberPad,
}

/// A conditional Shortcuts sentence in `@AssistantAction(summaries: [...])`.
sealed class SummaryCondition {
  const SummaryCondition();
}

/// Comparison operators for [SummaryWhen] (`When(\.$param, ...)`).
enum SummaryComparison {
  equalTo,
  notEqualTo,
  hasAnyValue,
  hasNoValue,
  lessThan,
  lessThanOrEqualTo,
  greaterThan,
  greaterThanOrEqualTo,
}

/// Shows [then] when [param] matches [value] (using [comparison]), and
/// [otherwise] (or the next condition in `summaries` / the action's `summary`)
/// when it does not.
///
/// ```dart
/// @AssistantAction(
///   title: 'Start Timer',
///   summaries: [
///     SummaryWhen('now', value: true, then: 'Start {label} right now', otherwise: 'Start {label} in {minutes}m'),
///   ],
/// )
/// ```
class SummaryWhen extends SummaryCondition {
  const SummaryWhen(
    this.param, {
    this.value,
    this.comparison = SummaryComparison.equalTo,
    required this.then,
    this.otherwise,
  });

  /// Shows [then] when optional parameter [param] has a value.
  const SummaryWhen.hasValue(
    this.param, {
    required this.then,
    this.otherwise,
  })  : value = null,
        comparison = SummaryComparison.hasAnyValue;

  /// Shows [then] when optional parameter [param] has no value.
  const SummaryWhen.hasNoValue(
    this.param, {
    required this.then,
    this.otherwise,
  })  : value = null,
        comparison = SummaryComparison.hasNoValue;

  /// The action parameter name being tested.
  final String param;

  /// The constant value compared against [param] (`bool`, `int`, `double`,
  /// `String`, or an enum case). Unused for [SummaryComparison.hasAnyValue] and
  /// [SummaryComparison.hasNoValue].
  final Object? value;

  final SummaryComparison comparison;

  /// Shortcuts sentence when the condition holds (`{name}` interpolates
  /// parameter `name`).
  final String then;

  /// Shortcuts sentence when the condition does not hold. When omitted, the
  /// next entry in `summaries` (or the action's `summary`) is used.
  final String? otherwise;
}

/// Branches the Shortcuts sentence on an enum parameter's cases
/// (`Switch(\.$param) { Case(.a) { Summary(...) } DefaultCase { Summary(...) } }`).
///
/// ```dart
/// @AssistantAction(
///   title: 'Brew Drink',
///   summaries: [
///     SummarySwitch(
///       'size',
///       cases: {
///         DrinkSize.small: 'Brew a quick {drink}',
///         DrinkSize.large: 'Brew a large {drink} with {shots} shots',
///       },
///       defaultSummary: 'Brew a {size} {drink}',
///     ),
///   ],
/// )
/// ```
class SummarySwitch extends SummaryCondition {
  const SummarySwitch(
    this.param, {
    required this.cases,
    this.defaultSummary,
  });

  /// The enum parameter name on the action.
  final String param;

  /// Enum constant -> Shortcuts sentence template.
  final Map<Enum, String> cases;

  /// Fallback sentence (`DefaultCase`) for enum cases not listed in [cases].
  final String? defaultSummary;
}

// ── Currency & Measurements ─────────────────────────────────────────────────

/// A monetary amount and ISO 4217 currency code (`IntentCurrencyAmount`), such
/// as `AssistantCurrency(amount: 12.50, currencyCode: 'USD')`.
class AssistantCurrency {
  const AssistantCurrency({required this.amount, required this.currencyCode});

  factory AssistantCurrency.fromJson(Map<String, Object?> json) => AssistantCurrency(
        amount: (json['amount'] as num).toDouble(),
        currencyCode: (json['currencyCode'] as String).toUpperCase(),
      );

  final double amount;

  /// Three-letter ISO 4217 code, such as `'USD'`, `'EUR'`, `'GBP'`, or `'JPY'`.
  final String currencyCode;

  Map<String, Object?> toJson() => {'amount': amount, 'currencyCode': currencyCode};

  @override
  bool operator ==(Object other) =>
      other is AssistantCurrency && other.amount == amount && other.currencyCode == currencyCode;

  @override
  int get hashCode => Object.hash(amount, currencyCode);

  @override
  String toString() => 'AssistantCurrency($amount $currencyCode)';
}

/// Units for [AssistantLength] (`Foundation.UnitLength`).
enum LengthUnit {
  meters,
  kilometers,
  centimeters,
  millimeters,
  miles,
  yards,
  feet,
  inches,
}

/// A length or distance (`Measurement<UnitLength>`).
class AssistantLength {
  const AssistantLength({required this.value, this.unit = LengthUnit.meters});
  const AssistantLength.meters(this.value) : unit = LengthUnit.meters;
  const AssistantLength.kilometers(this.value) : unit = LengthUnit.kilometers;
  const AssistantLength.miles(this.value) : unit = LengthUnit.miles;

  factory AssistantLength.fromJson(Map<String, Object?> json) => AssistantLength(
        value: (json['value'] as num).toDouble(),
        unit: _unitByName(LengthUnit.values, json['unit'], LengthUnit.meters),
      );

  final double value;
  final LengthUnit unit;

  Map<String, Object?> toJson() => {'value': value, 'unit': unit.name};

  @override
  bool operator ==(Object other) => other is AssistantLength && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => 'AssistantLength($value ${unit.name})';
}

/// Units for [AssistantMass] (`Foundation.UnitMass`).
enum MassUnit {
  kilograms,
  grams,
  milligrams,
  metricTons,
  pounds,
  ounces,
  stones,
}

/// A mass or weight (`Measurement<UnitMass>`).
class AssistantMass {
  const AssistantMass({required this.value, this.unit = MassUnit.kilograms});
  const AssistantMass.kilograms(this.value) : unit = MassUnit.kilograms;
  const AssistantMass.grams(this.value) : unit = MassUnit.grams;
  const AssistantMass.pounds(this.value) : unit = MassUnit.pounds;

  factory AssistantMass.fromJson(Map<String, Object?> json) => AssistantMass(
        value: (json['value'] as num).toDouble(),
        unit: _unitByName(MassUnit.values, json['unit'], MassUnit.kilograms),
      );

  final double value;
  final MassUnit unit;

  Map<String, Object?> toJson() => {'value': value, 'unit': unit.name};

  @override
  bool operator ==(Object other) => other is AssistantMass && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => 'AssistantMass($value ${unit.name})';
}

/// Units for [AssistantTemperature] (`Foundation.UnitTemperature`).
enum TemperatureUnit {
  celsius,
  fahrenheit,
  kelvin,
}

/// A temperature (`Measurement<UnitTemperature>`).
class AssistantTemperature {
  const AssistantTemperature({required this.value, this.unit = TemperatureUnit.celsius});
  const AssistantTemperature.celsius(this.value) : unit = TemperatureUnit.celsius;
  const AssistantTemperature.fahrenheit(this.value) : unit = TemperatureUnit.fahrenheit;
  const AssistantTemperature.kelvin(this.value) : unit = TemperatureUnit.kelvin;

  factory AssistantTemperature.fromJson(Map<String, Object?> json) => AssistantTemperature(
        value: (json['value'] as num).toDouble(),
        unit: _unitByName(TemperatureUnit.values, json['unit'], TemperatureUnit.celsius),
      );

  final double value;
  final TemperatureUnit unit;

  Map<String, Object?> toJson() => {'value': value, 'unit': unit.name};

  @override
  bool operator ==(Object other) => other is AssistantTemperature && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => 'AssistantTemperature($value ${unit.name})';
}

/// Units for [AssistantVolume] (`Foundation.UnitVolume`).
enum VolumeUnit {
  liters,
  milliliters,
  cubicMeters,
  gallons,
  quarts,
  pints,
  cups,
  fluidOunces,
}

/// A liquid or dry volume (`Measurement<UnitVolume>`).
class AssistantVolume {
  const AssistantVolume({required this.value, this.unit = VolumeUnit.liters});
  const AssistantVolume.liters(this.value) : unit = VolumeUnit.liters;
  const AssistantVolume.milliliters(this.value) : unit = VolumeUnit.milliliters;
  const AssistantVolume.fluidOunces(this.value) : unit = VolumeUnit.fluidOunces;

  factory AssistantVolume.fromJson(Map<String, Object?> json) => AssistantVolume(
        value: (json['value'] as num).toDouble(),
        unit: _unitByName(VolumeUnit.values, json['unit'], VolumeUnit.liters),
      );

  final double value;
  final VolumeUnit unit;

  Map<String, Object?> toJson() => {'value': value, 'unit': unit.name};

  @override
  bool operator ==(Object other) => other is AssistantVolume && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => 'AssistantVolume($value ${unit.name})';
}

/// Units for [AssistantSpeed] (`Foundation.UnitSpeed`).
enum SpeedUnit {
  metersPerSecond,
  kilometersPerHour,
  milesPerHour,
  knots,
}

/// A speed (`Measurement<UnitSpeed>`).
class AssistantSpeed {
  const AssistantSpeed({required this.value, this.unit = SpeedUnit.metersPerSecond});
  const AssistantSpeed.metersPerSecond(this.value) : unit = SpeedUnit.metersPerSecond;
  const AssistantSpeed.kilometersPerHour(this.value) : unit = SpeedUnit.kilometersPerHour;
  const AssistantSpeed.milesPerHour(this.value) : unit = SpeedUnit.milesPerHour;

  factory AssistantSpeed.fromJson(Map<String, Object?> json) => AssistantSpeed(
        value: (json['value'] as num).toDouble(),
        unit: _unitByName(SpeedUnit.values, json['unit'], SpeedUnit.metersPerSecond),
      );

  final double value;
  final SpeedUnit unit;

  Map<String, Object?> toJson() => {'value': value, 'unit': unit.name};

  @override
  bool operator ==(Object other) => other is AssistantSpeed && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => 'AssistantSpeed($value ${unit.name})';
}

/// Units for [AssistantEnergy] (`Foundation.UnitEnergy`).
enum EnergyUnit {
  joules,
  kilojoules,
  calories,
  kilocalories,
  kilowattHours,
}

/// An energy measurement (`Measurement<UnitEnergy>`).
class AssistantEnergy {
  const AssistantEnergy({required this.value, this.unit = EnergyUnit.kilocalories});
  const AssistantEnergy.joules(this.value) : unit = EnergyUnit.joules;
  const AssistantEnergy.kilocalories(this.value) : unit = EnergyUnit.kilocalories;
  const AssistantEnergy.kilowattHours(this.value) : unit = EnergyUnit.kilowattHours;

  factory AssistantEnergy.fromJson(Map<String, Object?> json) => AssistantEnergy(
        value: (json['value'] as num).toDouble(),
        unit: _unitByName(EnergyUnit.values, json['unit'], EnergyUnit.kilocalories),
      );

  final double value;
  final EnergyUnit unit;

  Map<String, Object?> toJson() => {'value': value, 'unit': unit.name};

  @override
  bool operator ==(Object other) => other is AssistantEnergy && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => 'AssistantEnergy($value ${unit.name})';
}

T _unitByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw is String) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
  }
  return fallback;
}
