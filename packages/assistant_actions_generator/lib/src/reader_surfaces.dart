part of 'reader.dart';

/// System surfaces beyond Siri: Focus filters.
extension _Surfaces on ModelReader {
  /// `@AssistantFocusFilter` on a top-level function: a `SetFocusFilterIntent`
  /// whose parameters are the function's. The system creates the filter with
  /// its parameters' defaults (and runs it with them when the Focus turns
  /// off), so each one is nullable or has a constant default Swift can state.
  Future<ActionModel> _focusFilter(
      TopLevelFunctionElement fn, ConstantReader annotation, List<EntityModel> entities) async {
    InvalidGenerationSourceError error(String message) =>
        InvalidGenerationSourceError('${fn.displayName}: $message', element: fn);

    if (_annotation(fn, 'AssistantAction') != null) {
      throw error('a function is either an @AssistantAction or an @AssistantFocusFilter, not both.');
    }
    final result = fn.returnType;
    final inner = result.isDartAsyncFuture || result.isDartAsyncFutureOr
        ? (result as InterfaceType).typeArguments.single
        : result;
    if (inner is! VoidType && !inner.isDartCoreNull) {
      throw error('a Focus filter returns void (optionally in a Future), not ${result.getDisplayString()}.');
    }
    final params = <ParamModel>[];
    for (final p in fn.formalParameters) {
      final param = await _param(fn, p, entities);
      // `_param` gives defaults App Intents can state as Swift literals.
      final swiftDefault = param.swiftDefault;
      if (p.hasDefaultValue) {
        final value = p.computeConstantValue();
        // `= null` on a nullable parameter says nothing more.
        if (swiftDefault == null && !(param.nullable && (value?.isNull ?? false))) {
          throw error('the default of ${p.displayName} must be a bool, int, double, String or enum constant; '
              'make it nullable instead.');
        }
      }
      if (!param.nullable && swiftDefault == null) {
        throw error('${p.displayName} needs a default value or a nullable type: the system creates the '
            'filter with its defaults, and runs it with them when the Focus turns off.');
      }
      params.add(ParamModel(
        name: param.name,
        title: param.title,
        named: param.named,
        prompt: param.prompt,
        value: param.value,
        entity: param.entity,
        entityNullable: param.entityNullable,
        entityList: param.entityList,
        swiftDefault: swiftDefault,
        defaultDart: param.defaultDart,
      ));
    }
    final summary = annotation.peek('summary')?.stringValue;
    for (final match in RegExp(r'\{(\w+)\}').allMatches(summary ?? '')) {
      final p = params.where((p) => p.name == match.group(1)).firstOrNull;
      if (p == null) throw error('summary uses {${match.group(1)}}, which is not a parameter.');
      if (!_Actions._speakable(p)) throw error('summary uses {${p.name}}, which Settings can\'t show as text.');
    }
    return ActionModel(
      functionName: fn.displayName,
      library: fn.library.uri,
      title: annotation.read('title').stringValue,
      description: annotation.peek('description')?.stringValue,
      runs: RunsModel.deferred,
      params: params,
      returnsString: false,
      focusFilter: FocusFilterModel(summary: summary),
    );
  }
}
