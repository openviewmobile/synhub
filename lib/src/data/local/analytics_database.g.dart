// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'analytics_database.dart';

// ignore_for_file: type=lint
class $UsageEventsTable extends UsageEvents
    with TableInfo<$UsageEventsTable, UsageEventRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UsageEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _atMsMeta = const VerificationMeta('atMs');
  @override
  late final GeneratedColumn<int> atMs = GeneratedColumn<int>(
    'at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _moduleMeta = const VerificationMeta('module');
  @override
  late final GeneratedColumn<String> module = GeneratedColumn<String>(
    'module',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actionMeta = const VerificationMeta('action');
  @override
  late final GeneratedColumn<String> action = GeneratedColumn<String>(
    'action',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _objectMeta = const VerificationMeta('object');
  @override
  late final GeneratedColumn<String> object = GeneratedColumn<String>(
    'object',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<int> value = GeneratedColumn<int>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _detailMeta = const VerificationMeta('detail');
  @override
  late final GeneratedColumn<String> detail = GeneratedColumn<String>(
    'detail',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _sessionMeta = const VerificationMeta(
    'session',
  );
  @override
  late final GeneratedColumn<String> session = GeneratedColumn<String>(
    'session',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _accountMeta = const VerificationMeta(
    'account',
  );
  @override
  late final GeneratedColumn<String> account = GeneratedColumn<String>(
    'account',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    atMs,
    module,
    action,
    object,
    value,
    detail,
    session,
    account,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'usage_events';
  @override
  VerificationContext validateIntegrity(
    Insertable<UsageEventRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('at_ms')) {
      context.handle(
        _atMsMeta,
        atMs.isAcceptableOrUnknown(data['at_ms']!, _atMsMeta),
      );
    } else if (isInserting) {
      context.missing(_atMsMeta);
    }
    if (data.containsKey('module')) {
      context.handle(
        _moduleMeta,
        module.isAcceptableOrUnknown(data['module']!, _moduleMeta),
      );
    } else if (isInserting) {
      context.missing(_moduleMeta);
    }
    if (data.containsKey('action')) {
      context.handle(
        _actionMeta,
        action.isAcceptableOrUnknown(data['action']!, _actionMeta),
      );
    } else if (isInserting) {
      context.missing(_actionMeta);
    }
    if (data.containsKey('object')) {
      context.handle(
        _objectMeta,
        object.isAcceptableOrUnknown(data['object']!, _objectMeta),
      );
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    }
    if (data.containsKey('detail')) {
      context.handle(
        _detailMeta,
        detail.isAcceptableOrUnknown(data['detail']!, _detailMeta),
      );
    }
    if (data.containsKey('session')) {
      context.handle(
        _sessionMeta,
        session.isAcceptableOrUnknown(data['session']!, _sessionMeta),
      );
    }
    if (data.containsKey('account')) {
      context.handle(
        _accountMeta,
        account.isAcceptableOrUnknown(data['account']!, _accountMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  UsageEventRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UsageEventRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      atMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}at_ms'],
      )!,
      module: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}module'],
      )!,
      action: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}action'],
      )!,
      object: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}object'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}value'],
      )!,
      detail: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}detail'],
      )!,
      session: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session'],
      )!,
      account: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account'],
      )!,
    );
  }

  @override
  $UsageEventsTable createAlias(String alias) {
    return $UsageEventsTable(attachedDatabase, alias);
  }
}

class UsageEventRow extends DataClass implements Insertable<UsageEventRow> {
  final int id;

  /// 发生时间（epoch 毫秒）
  final int atMs;

  /// 模块：files / notes / photos / calendar / contacts / chat / drive /
  /// workspace / reader / settings / search…（见 `UsageModule`）
  final String module;

  /// 动作：open / preview / search / upload / download / create / edit /
  /// delete / switch_section / share / label…（见 `UsageAction`）
  final String action;

  /// "对象类型"，**不含具体名字**：文件扩展名（`.docx`）、条目类型
  /// （`folder`/`note`/`album`/`event`）、板块名等
  final String object;

  /// 可选数值：大小（字节）、耗时（毫秒）、结果条数、第几页…
  final int value;

  /// 其它脱敏上下文（JSON）：如 `{"source":"drive","kind":"image"}`
  final String detail;

  /// 会话 id（同一段连续使用共享一个值；由 UsageLog 按"间隔 > 5 分钟"切分）
  final String session;

  /// 账号假名（加盐哈希前 12 位），多账号共用一台设备时能分开看
  final String account;
  const UsageEventRow({
    required this.id,
    required this.atMs,
    required this.module,
    required this.action,
    required this.object,
    required this.value,
    required this.detail,
    required this.session,
    required this.account,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['at_ms'] = Variable<int>(atMs);
    map['module'] = Variable<String>(module);
    map['action'] = Variable<String>(action);
    map['object'] = Variable<String>(object);
    map['value'] = Variable<int>(value);
    map['detail'] = Variable<String>(detail);
    map['session'] = Variable<String>(session);
    map['account'] = Variable<String>(account);
    return map;
  }

  UsageEventsCompanion toCompanion(bool nullToAbsent) {
    return UsageEventsCompanion(
      id: Value(id),
      atMs: Value(atMs),
      module: Value(module),
      action: Value(action),
      object: Value(object),
      value: Value(value),
      detail: Value(detail),
      session: Value(session),
      account: Value(account),
    );
  }

  factory UsageEventRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UsageEventRow(
      id: serializer.fromJson<int>(json['id']),
      atMs: serializer.fromJson<int>(json['atMs']),
      module: serializer.fromJson<String>(json['module']),
      action: serializer.fromJson<String>(json['action']),
      object: serializer.fromJson<String>(json['object']),
      value: serializer.fromJson<int>(json['value']),
      detail: serializer.fromJson<String>(json['detail']),
      session: serializer.fromJson<String>(json['session']),
      account: serializer.fromJson<String>(json['account']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'atMs': serializer.toJson<int>(atMs),
      'module': serializer.toJson<String>(module),
      'action': serializer.toJson<String>(action),
      'object': serializer.toJson<String>(object),
      'value': serializer.toJson<int>(value),
      'detail': serializer.toJson<String>(detail),
      'session': serializer.toJson<String>(session),
      'account': serializer.toJson<String>(account),
    };
  }

  UsageEventRow copyWith({
    int? id,
    int? atMs,
    String? module,
    String? action,
    String? object,
    int? value,
    String? detail,
    String? session,
    String? account,
  }) => UsageEventRow(
    id: id ?? this.id,
    atMs: atMs ?? this.atMs,
    module: module ?? this.module,
    action: action ?? this.action,
    object: object ?? this.object,
    value: value ?? this.value,
    detail: detail ?? this.detail,
    session: session ?? this.session,
    account: account ?? this.account,
  );
  UsageEventRow copyWithCompanion(UsageEventsCompanion data) {
    return UsageEventRow(
      id: data.id.present ? data.id.value : this.id,
      atMs: data.atMs.present ? data.atMs.value : this.atMs,
      module: data.module.present ? data.module.value : this.module,
      action: data.action.present ? data.action.value : this.action,
      object: data.object.present ? data.object.value : this.object,
      value: data.value.present ? data.value.value : this.value,
      detail: data.detail.present ? data.detail.value : this.detail,
      session: data.session.present ? data.session.value : this.session,
      account: data.account.present ? data.account.value : this.account,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UsageEventRow(')
          ..write('id: $id, ')
          ..write('atMs: $atMs, ')
          ..write('module: $module, ')
          ..write('action: $action, ')
          ..write('object: $object, ')
          ..write('value: $value, ')
          ..write('detail: $detail, ')
          ..write('session: $session, ')
          ..write('account: $account')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    atMs,
    module,
    action,
    object,
    value,
    detail,
    session,
    account,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UsageEventRow &&
          other.id == this.id &&
          other.atMs == this.atMs &&
          other.module == this.module &&
          other.action == this.action &&
          other.object == this.object &&
          other.value == this.value &&
          other.detail == this.detail &&
          other.session == this.session &&
          other.account == this.account);
}

class UsageEventsCompanion extends UpdateCompanion<UsageEventRow> {
  final Value<int> id;
  final Value<int> atMs;
  final Value<String> module;
  final Value<String> action;
  final Value<String> object;
  final Value<int> value;
  final Value<String> detail;
  final Value<String> session;
  final Value<String> account;
  const UsageEventsCompanion({
    this.id = const Value.absent(),
    this.atMs = const Value.absent(),
    this.module = const Value.absent(),
    this.action = const Value.absent(),
    this.object = const Value.absent(),
    this.value = const Value.absent(),
    this.detail = const Value.absent(),
    this.session = const Value.absent(),
    this.account = const Value.absent(),
  });
  UsageEventsCompanion.insert({
    this.id = const Value.absent(),
    required int atMs,
    required String module,
    required String action,
    this.object = const Value.absent(),
    this.value = const Value.absent(),
    this.detail = const Value.absent(),
    this.session = const Value.absent(),
    this.account = const Value.absent(),
  }) : atMs = Value(atMs),
       module = Value(module),
       action = Value(action);
  static Insertable<UsageEventRow> custom({
    Expression<int>? id,
    Expression<int>? atMs,
    Expression<String>? module,
    Expression<String>? action,
    Expression<String>? object,
    Expression<int>? value,
    Expression<String>? detail,
    Expression<String>? session,
    Expression<String>? account,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (atMs != null) 'at_ms': atMs,
      if (module != null) 'module': module,
      if (action != null) 'action': action,
      if (object != null) 'object': object,
      if (value != null) 'value': value,
      if (detail != null) 'detail': detail,
      if (session != null) 'session': session,
      if (account != null) 'account': account,
    });
  }

  UsageEventsCompanion copyWith({
    Value<int>? id,
    Value<int>? atMs,
    Value<String>? module,
    Value<String>? action,
    Value<String>? object,
    Value<int>? value,
    Value<String>? detail,
    Value<String>? session,
    Value<String>? account,
  }) {
    return UsageEventsCompanion(
      id: id ?? this.id,
      atMs: atMs ?? this.atMs,
      module: module ?? this.module,
      action: action ?? this.action,
      object: object ?? this.object,
      value: value ?? this.value,
      detail: detail ?? this.detail,
      session: session ?? this.session,
      account: account ?? this.account,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (atMs.present) {
      map['at_ms'] = Variable<int>(atMs.value);
    }
    if (module.present) {
      map['module'] = Variable<String>(module.value);
    }
    if (action.present) {
      map['action'] = Variable<String>(action.value);
    }
    if (object.present) {
      map['object'] = Variable<String>(object.value);
    }
    if (value.present) {
      map['value'] = Variable<int>(value.value);
    }
    if (detail.present) {
      map['detail'] = Variable<String>(detail.value);
    }
    if (session.present) {
      map['session'] = Variable<String>(session.value);
    }
    if (account.present) {
      map['account'] = Variable<String>(account.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UsageEventsCompanion(')
          ..write('id: $id, ')
          ..write('atMs: $atMs, ')
          ..write('module: $module, ')
          ..write('action: $action, ')
          ..write('object: $object, ')
          ..write('value: $value, ')
          ..write('detail: $detail, ')
          ..write('session: $session, ')
          ..write('account: $account')
          ..write(')'))
        .toString();
  }
}

class $UsageInsightsTable extends UsageInsights
    with TableInfo<$UsageInsightsTable, UsageInsightRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UsageInsightsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _generatedAtMsMeta = const VerificationMeta(
    'generatedAtMs',
  );
  @override
  late final GeneratedColumn<int> generatedAtMs = GeneratedColumn<int>(
    'generated_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _suggestionMeta = const VerificationMeta(
    'suggestion',
  );
  @override
  late final GeneratedColumn<String> suggestion = GeneratedColumn<String>(
    'suggestion',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _scoreMeta = const VerificationMeta('score');
  @override
  late final GeneratedColumn<double> score = GeneratedColumn<double>(
    'score',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _evidenceMeta = const VerificationMeta(
    'evidence',
  );
  @override
  late final GeneratedColumn<String> evidence = GeneratedColumn<String>(
    'evidence',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('heuristic'),
  );
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
    'model',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _appliedAtMsMeta = const VerificationMeta(
    'appliedAtMs',
  );
  @override
  late final GeneratedColumn<int> appliedAtMs = GeneratedColumn<int>(
    'applied_at_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    generatedAtMs,
    kind,
    title,
    body,
    suggestion,
    score,
    evidence,
    source,
    model,
    appliedAtMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'usage_insights';
  @override
  VerificationContext validateIntegrity(
    Insertable<UsageInsightRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('generated_at_ms')) {
      context.handle(
        _generatedAtMsMeta,
        generatedAtMs.isAcceptableOrUnknown(
          data['generated_at_ms']!,
          _generatedAtMsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_generatedAtMsMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('suggestion')) {
      context.handle(
        _suggestionMeta,
        suggestion.isAcceptableOrUnknown(data['suggestion']!, _suggestionMeta),
      );
    }
    if (data.containsKey('score')) {
      context.handle(
        _scoreMeta,
        score.isAcceptableOrUnknown(data['score']!, _scoreMeta),
      );
    }
    if (data.containsKey('evidence')) {
      context.handle(
        _evidenceMeta,
        evidence.isAcceptableOrUnknown(data['evidence']!, _evidenceMeta),
      );
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('model')) {
      context.handle(
        _modelMeta,
        model.isAcceptableOrUnknown(data['model']!, _modelMeta),
      );
    }
    if (data.containsKey('applied_at_ms')) {
      context.handle(
        _appliedAtMsMeta,
        appliedAtMs.isAcceptableOrUnknown(
          data['applied_at_ms']!,
          _appliedAtMsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  UsageInsightRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UsageInsightRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      generatedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}generated_at_ms'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      suggestion: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}suggestion'],
      )!,
      score: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}score'],
      )!,
      evidence: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}evidence'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      model: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model'],
      )!,
      appliedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}applied_at_ms'],
      )!,
    );
  }

  @override
  $UsageInsightsTable createAlias(String alias) {
    return $UsageInsightsTable(attachedDatabase, alias);
  }
}

class UsageInsightRow extends DataClass implements Insertable<UsageInsightRow> {
  final int id;

  /// 生成时间（epoch 毫秒）
  final int generatedAtMs;

  /// 结论类型：peak_hour / top_module / unused_module / search_quality /
  /// file_type_pref / transfer_mix / edit_cadence / session_length /
  /// weekday_pattern / feature_gap…（见 `InsightKind`）
  final String kind;
  final String title;
  final String body;
  final String suggestion;

  /// 可信度 / 重要性（0–1，样本不足会调低）
  final double score;

  /// 支撑证据（JSON：统计口径 + 数字，便于复核与喂给模型）
  final String evidence;

  /// 来源：`heuristic`（本地规则）/ `on_device_llm`（端侧模型）
  final String source;

  /// 模型标识（端侧模型产出的结论才有）
  final String model;

  /// 这条建议被应用到 App 策略的时间（0 = 还没应用）
  final int appliedAtMs;
  const UsageInsightRow({
    required this.id,
    required this.generatedAtMs,
    required this.kind,
    required this.title,
    required this.body,
    required this.suggestion,
    required this.score,
    required this.evidence,
    required this.source,
    required this.model,
    required this.appliedAtMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['generated_at_ms'] = Variable<int>(generatedAtMs);
    map['kind'] = Variable<String>(kind);
    map['title'] = Variable<String>(title);
    map['body'] = Variable<String>(body);
    map['suggestion'] = Variable<String>(suggestion);
    map['score'] = Variable<double>(score);
    map['evidence'] = Variable<String>(evidence);
    map['source'] = Variable<String>(source);
    map['model'] = Variable<String>(model);
    map['applied_at_ms'] = Variable<int>(appliedAtMs);
    return map;
  }

  UsageInsightsCompanion toCompanion(bool nullToAbsent) {
    return UsageInsightsCompanion(
      id: Value(id),
      generatedAtMs: Value(generatedAtMs),
      kind: Value(kind),
      title: Value(title),
      body: Value(body),
      suggestion: Value(suggestion),
      score: Value(score),
      evidence: Value(evidence),
      source: Value(source),
      model: Value(model),
      appliedAtMs: Value(appliedAtMs),
    );
  }

  factory UsageInsightRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UsageInsightRow(
      id: serializer.fromJson<int>(json['id']),
      generatedAtMs: serializer.fromJson<int>(json['generatedAtMs']),
      kind: serializer.fromJson<String>(json['kind']),
      title: serializer.fromJson<String>(json['title']),
      body: serializer.fromJson<String>(json['body']),
      suggestion: serializer.fromJson<String>(json['suggestion']),
      score: serializer.fromJson<double>(json['score']),
      evidence: serializer.fromJson<String>(json['evidence']),
      source: serializer.fromJson<String>(json['source']),
      model: serializer.fromJson<String>(json['model']),
      appliedAtMs: serializer.fromJson<int>(json['appliedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'generatedAtMs': serializer.toJson<int>(generatedAtMs),
      'kind': serializer.toJson<String>(kind),
      'title': serializer.toJson<String>(title),
      'body': serializer.toJson<String>(body),
      'suggestion': serializer.toJson<String>(suggestion),
      'score': serializer.toJson<double>(score),
      'evidence': serializer.toJson<String>(evidence),
      'source': serializer.toJson<String>(source),
      'model': serializer.toJson<String>(model),
      'appliedAtMs': serializer.toJson<int>(appliedAtMs),
    };
  }

  UsageInsightRow copyWith({
    int? id,
    int? generatedAtMs,
    String? kind,
    String? title,
    String? body,
    String? suggestion,
    double? score,
    String? evidence,
    String? source,
    String? model,
    int? appliedAtMs,
  }) => UsageInsightRow(
    id: id ?? this.id,
    generatedAtMs: generatedAtMs ?? this.generatedAtMs,
    kind: kind ?? this.kind,
    title: title ?? this.title,
    body: body ?? this.body,
    suggestion: suggestion ?? this.suggestion,
    score: score ?? this.score,
    evidence: evidence ?? this.evidence,
    source: source ?? this.source,
    model: model ?? this.model,
    appliedAtMs: appliedAtMs ?? this.appliedAtMs,
  );
  UsageInsightRow copyWithCompanion(UsageInsightsCompanion data) {
    return UsageInsightRow(
      id: data.id.present ? data.id.value : this.id,
      generatedAtMs: data.generatedAtMs.present
          ? data.generatedAtMs.value
          : this.generatedAtMs,
      kind: data.kind.present ? data.kind.value : this.kind,
      title: data.title.present ? data.title.value : this.title,
      body: data.body.present ? data.body.value : this.body,
      suggestion: data.suggestion.present
          ? data.suggestion.value
          : this.suggestion,
      score: data.score.present ? data.score.value : this.score,
      evidence: data.evidence.present ? data.evidence.value : this.evidence,
      source: data.source.present ? data.source.value : this.source,
      model: data.model.present ? data.model.value : this.model,
      appliedAtMs: data.appliedAtMs.present
          ? data.appliedAtMs.value
          : this.appliedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UsageInsightRow(')
          ..write('id: $id, ')
          ..write('generatedAtMs: $generatedAtMs, ')
          ..write('kind: $kind, ')
          ..write('title: $title, ')
          ..write('body: $body, ')
          ..write('suggestion: $suggestion, ')
          ..write('score: $score, ')
          ..write('evidence: $evidence, ')
          ..write('source: $source, ')
          ..write('model: $model, ')
          ..write('appliedAtMs: $appliedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    generatedAtMs,
    kind,
    title,
    body,
    suggestion,
    score,
    evidence,
    source,
    model,
    appliedAtMs,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UsageInsightRow &&
          other.id == this.id &&
          other.generatedAtMs == this.generatedAtMs &&
          other.kind == this.kind &&
          other.title == this.title &&
          other.body == this.body &&
          other.suggestion == this.suggestion &&
          other.score == this.score &&
          other.evidence == this.evidence &&
          other.source == this.source &&
          other.model == this.model &&
          other.appliedAtMs == this.appliedAtMs);
}

class UsageInsightsCompanion extends UpdateCompanion<UsageInsightRow> {
  final Value<int> id;
  final Value<int> generatedAtMs;
  final Value<String> kind;
  final Value<String> title;
  final Value<String> body;
  final Value<String> suggestion;
  final Value<double> score;
  final Value<String> evidence;
  final Value<String> source;
  final Value<String> model;
  final Value<int> appliedAtMs;
  const UsageInsightsCompanion({
    this.id = const Value.absent(),
    this.generatedAtMs = const Value.absent(),
    this.kind = const Value.absent(),
    this.title = const Value.absent(),
    this.body = const Value.absent(),
    this.suggestion = const Value.absent(),
    this.score = const Value.absent(),
    this.evidence = const Value.absent(),
    this.source = const Value.absent(),
    this.model = const Value.absent(),
    this.appliedAtMs = const Value.absent(),
  });
  UsageInsightsCompanion.insert({
    this.id = const Value.absent(),
    required int generatedAtMs,
    required String kind,
    required String title,
    required String body,
    this.suggestion = const Value.absent(),
    this.score = const Value.absent(),
    this.evidence = const Value.absent(),
    this.source = const Value.absent(),
    this.model = const Value.absent(),
    this.appliedAtMs = const Value.absent(),
  }) : generatedAtMs = Value(generatedAtMs),
       kind = Value(kind),
       title = Value(title),
       body = Value(body);
  static Insertable<UsageInsightRow> custom({
    Expression<int>? id,
    Expression<int>? generatedAtMs,
    Expression<String>? kind,
    Expression<String>? title,
    Expression<String>? body,
    Expression<String>? suggestion,
    Expression<double>? score,
    Expression<String>? evidence,
    Expression<String>? source,
    Expression<String>? model,
    Expression<int>? appliedAtMs,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (generatedAtMs != null) 'generated_at_ms': generatedAtMs,
      if (kind != null) 'kind': kind,
      if (title != null) 'title': title,
      if (body != null) 'body': body,
      if (suggestion != null) 'suggestion': suggestion,
      if (score != null) 'score': score,
      if (evidence != null) 'evidence': evidence,
      if (source != null) 'source': source,
      if (model != null) 'model': model,
      if (appliedAtMs != null) 'applied_at_ms': appliedAtMs,
    });
  }

  UsageInsightsCompanion copyWith({
    Value<int>? id,
    Value<int>? generatedAtMs,
    Value<String>? kind,
    Value<String>? title,
    Value<String>? body,
    Value<String>? suggestion,
    Value<double>? score,
    Value<String>? evidence,
    Value<String>? source,
    Value<String>? model,
    Value<int>? appliedAtMs,
  }) {
    return UsageInsightsCompanion(
      id: id ?? this.id,
      generatedAtMs: generatedAtMs ?? this.generatedAtMs,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      body: body ?? this.body,
      suggestion: suggestion ?? this.suggestion,
      score: score ?? this.score,
      evidence: evidence ?? this.evidence,
      source: source ?? this.source,
      model: model ?? this.model,
      appliedAtMs: appliedAtMs ?? this.appliedAtMs,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (generatedAtMs.present) {
      map['generated_at_ms'] = Variable<int>(generatedAtMs.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (suggestion.present) {
      map['suggestion'] = Variable<String>(suggestion.value);
    }
    if (score.present) {
      map['score'] = Variable<double>(score.value);
    }
    if (evidence.present) {
      map['evidence'] = Variable<String>(evidence.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (appliedAtMs.present) {
      map['applied_at_ms'] = Variable<int>(appliedAtMs.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UsageInsightsCompanion(')
          ..write('id: $id, ')
          ..write('generatedAtMs: $generatedAtMs, ')
          ..write('kind: $kind, ')
          ..write('title: $title, ')
          ..write('body: $body, ')
          ..write('suggestion: $suggestion, ')
          ..write('score: $score, ')
          ..write('evidence: $evidence, ')
          ..write('source: $source, ')
          ..write('model: $model, ')
          ..write('appliedAtMs: $appliedAtMs')
          ..write(')'))
        .toString();
  }
}

class $AnalyticsMetaRowsTable extends AnalyticsMetaRows
    with TableInfo<$AnalyticsMetaRowsTable, AnalyticsMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AnalyticsMetaRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'analytics_meta_rows';
  @override
  VerificationContext validateIntegrity(
    Insertable<AnalyticsMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AnalyticsMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AnalyticsMetaRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $AnalyticsMetaRowsTable createAlias(String alias) {
    return $AnalyticsMetaRowsTable(attachedDatabase, alias);
  }
}

class AnalyticsMetaRow extends DataClass
    implements Insertable<AnalyticsMetaRow> {
  final String key;
  final String value;
  const AnalyticsMetaRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AnalyticsMetaRowsCompanion toCompanion(bool nullToAbsent) {
    return AnalyticsMetaRowsCompanion(key: Value(key), value: Value(value));
  }

  factory AnalyticsMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AnalyticsMetaRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AnalyticsMetaRow copyWith({String? key, String? value}) =>
      AnalyticsMetaRow(key: key ?? this.key, value: value ?? this.value);
  AnalyticsMetaRow copyWithCompanion(AnalyticsMetaRowsCompanion data) {
    return AnalyticsMetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AnalyticsMetaRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AnalyticsMetaRow &&
          other.key == this.key &&
          other.value == this.value);
}

class AnalyticsMetaRowsCompanion extends UpdateCompanion<AnalyticsMetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AnalyticsMetaRowsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AnalyticsMetaRowsCompanion.insert({
    required String key,
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : key = Value(key);
  static Insertable<AnalyticsMetaRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AnalyticsMetaRowsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AnalyticsMetaRowsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AnalyticsMetaRowsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TrafficBucketsTable extends TrafficBuckets
    with TableInfo<$TrafficBucketsTable, TrafficBucketRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TrafficBucketsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _hourMsMeta = const VerificationMeta('hourMs');
  @override
  late final GeneratedColumn<int> hourMs = GeneratedColumn<int>(
    'hour_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _moduleMeta = const VerificationMeta('module');
  @override
  late final GeneratedColumn<String> module = GeneratedColumn<String>(
    'module',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _directionMeta = const VerificationMeta(
    'direction',
  );
  @override
  late final GeneratedColumn<String> direction = GeneratedColumn<String>(
    'direction',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tierMeta = const VerificationMeta('tier');
  @override
  late final GeneratedColumn<String> tier = GeneratedColumn<String>(
    'tier',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _transportMeta = const VerificationMeta(
    'transport',
  );
  @override
  late final GeneratedColumn<String> transport = GeneratedColumn<String>(
    'transport',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<int> bytes = GeneratedColumn<int>(
    'bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _samplesMeta = const VerificationMeta(
    'samples',
  );
  @override
  late final GeneratedColumn<int> samples = GeneratedColumn<int>(
    'samples',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    hourMs,
    module,
    direction,
    tier,
    transport,
    bytes,
    samples,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'traffic_buckets';
  @override
  VerificationContext validateIntegrity(
    Insertable<TrafficBucketRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('hour_ms')) {
      context.handle(
        _hourMsMeta,
        hourMs.isAcceptableOrUnknown(data['hour_ms']!, _hourMsMeta),
      );
    } else if (isInserting) {
      context.missing(_hourMsMeta);
    }
    if (data.containsKey('module')) {
      context.handle(
        _moduleMeta,
        module.isAcceptableOrUnknown(data['module']!, _moduleMeta),
      );
    } else if (isInserting) {
      context.missing(_moduleMeta);
    }
    if (data.containsKey('direction')) {
      context.handle(
        _directionMeta,
        direction.isAcceptableOrUnknown(data['direction']!, _directionMeta),
      );
    } else if (isInserting) {
      context.missing(_directionMeta);
    }
    if (data.containsKey('tier')) {
      context.handle(
        _tierMeta,
        tier.isAcceptableOrUnknown(data['tier']!, _tierMeta),
      );
    } else if (isInserting) {
      context.missing(_tierMeta);
    }
    if (data.containsKey('transport')) {
      context.handle(
        _transportMeta,
        transport.isAcceptableOrUnknown(data['transport']!, _transportMeta),
      );
    }
    if (data.containsKey('bytes')) {
      context.handle(
        _bytesMeta,
        bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta),
      );
    }
    if (data.containsKey('samples')) {
      context.handle(
        _samplesMeta,
        samples.isAcceptableOrUnknown(data['samples']!, _samplesMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TrafficBucketRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TrafficBucketRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      hourMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}hour_ms'],
      )!,
      module: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}module'],
      )!,
      direction: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}direction'],
      )!,
      tier: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tier'],
      )!,
      transport: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}transport'],
      )!,
      bytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bytes'],
      )!,
      samples: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}samples'],
      )!,
    );
  }

  @override
  $TrafficBucketsTable createAlias(String alias) {
    return $TrafficBucketsTable(attachedDatabase, alias);
  }
}

class TrafficBucketRow extends DataClass
    implements Insertable<TrafficBucketRow> {
  final int id;

  /// 小时桶的起点（**本地墙钟**的整点，epoch 毫秒）。
  ///
  /// 用本地墙钟而不是 UTC：用户问的是"我几点用的"，DST 切换时
  /// 会出现某个小时桶变长/变短，这是真实世界的语义（文档有说明）。
  final int hourMs;

  /// 模块 id（`UsageModule.id`；未归属是 `unattributed`）
  final String module;

  /// 方向：`down`（Rx）/ `up`（Tx）
  final String direction;

  /// 档位：`exact` / `estimated`
  final String tier;

  /// 接入方式：`wifi` / `mobile` / `other` / `''`（不知道）
  final String transport;

  /// 累计字节
  final int bytes;

  /// 累计样本数（精确档 = 请求次数；估算档 = 会话段数）——只作可信度参考
  final int samples;
  const TrafficBucketRow({
    required this.id,
    required this.hourMs,
    required this.module,
    required this.direction,
    required this.tier,
    required this.transport,
    required this.bytes,
    required this.samples,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['hour_ms'] = Variable<int>(hourMs);
    map['module'] = Variable<String>(module);
    map['direction'] = Variable<String>(direction);
    map['tier'] = Variable<String>(tier);
    map['transport'] = Variable<String>(transport);
    map['bytes'] = Variable<int>(bytes);
    map['samples'] = Variable<int>(samples);
    return map;
  }

  TrafficBucketsCompanion toCompanion(bool nullToAbsent) {
    return TrafficBucketsCompanion(
      id: Value(id),
      hourMs: Value(hourMs),
      module: Value(module),
      direction: Value(direction),
      tier: Value(tier),
      transport: Value(transport),
      bytes: Value(bytes),
      samples: Value(samples),
    );
  }

  factory TrafficBucketRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TrafficBucketRow(
      id: serializer.fromJson<int>(json['id']),
      hourMs: serializer.fromJson<int>(json['hourMs']),
      module: serializer.fromJson<String>(json['module']),
      direction: serializer.fromJson<String>(json['direction']),
      tier: serializer.fromJson<String>(json['tier']),
      transport: serializer.fromJson<String>(json['transport']),
      bytes: serializer.fromJson<int>(json['bytes']),
      samples: serializer.fromJson<int>(json['samples']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'hourMs': serializer.toJson<int>(hourMs),
      'module': serializer.toJson<String>(module),
      'direction': serializer.toJson<String>(direction),
      'tier': serializer.toJson<String>(tier),
      'transport': serializer.toJson<String>(transport),
      'bytes': serializer.toJson<int>(bytes),
      'samples': serializer.toJson<int>(samples),
    };
  }

  TrafficBucketRow copyWith({
    int? id,
    int? hourMs,
    String? module,
    String? direction,
    String? tier,
    String? transport,
    int? bytes,
    int? samples,
  }) => TrafficBucketRow(
    id: id ?? this.id,
    hourMs: hourMs ?? this.hourMs,
    module: module ?? this.module,
    direction: direction ?? this.direction,
    tier: tier ?? this.tier,
    transport: transport ?? this.transport,
    bytes: bytes ?? this.bytes,
    samples: samples ?? this.samples,
  );
  TrafficBucketRow copyWithCompanion(TrafficBucketsCompanion data) {
    return TrafficBucketRow(
      id: data.id.present ? data.id.value : this.id,
      hourMs: data.hourMs.present ? data.hourMs.value : this.hourMs,
      module: data.module.present ? data.module.value : this.module,
      direction: data.direction.present ? data.direction.value : this.direction,
      tier: data.tier.present ? data.tier.value : this.tier,
      transport: data.transport.present ? data.transport.value : this.transport,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      samples: data.samples.present ? data.samples.value : this.samples,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TrafficBucketRow(')
          ..write('id: $id, ')
          ..write('hourMs: $hourMs, ')
          ..write('module: $module, ')
          ..write('direction: $direction, ')
          ..write('tier: $tier, ')
          ..write('transport: $transport, ')
          ..write('bytes: $bytes, ')
          ..write('samples: $samples')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    hourMs,
    module,
    direction,
    tier,
    transport,
    bytes,
    samples,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TrafficBucketRow &&
          other.id == this.id &&
          other.hourMs == this.hourMs &&
          other.module == this.module &&
          other.direction == this.direction &&
          other.tier == this.tier &&
          other.transport == this.transport &&
          other.bytes == this.bytes &&
          other.samples == this.samples);
}

class TrafficBucketsCompanion extends UpdateCompanion<TrafficBucketRow> {
  final Value<int> id;
  final Value<int> hourMs;
  final Value<String> module;
  final Value<String> direction;
  final Value<String> tier;
  final Value<String> transport;
  final Value<int> bytes;
  final Value<int> samples;
  const TrafficBucketsCompanion({
    this.id = const Value.absent(),
    this.hourMs = const Value.absent(),
    this.module = const Value.absent(),
    this.direction = const Value.absent(),
    this.tier = const Value.absent(),
    this.transport = const Value.absent(),
    this.bytes = const Value.absent(),
    this.samples = const Value.absent(),
  });
  TrafficBucketsCompanion.insert({
    this.id = const Value.absent(),
    required int hourMs,
    required String module,
    required String direction,
    required String tier,
    this.transport = const Value.absent(),
    this.bytes = const Value.absent(),
    this.samples = const Value.absent(),
  }) : hourMs = Value(hourMs),
       module = Value(module),
       direction = Value(direction),
       tier = Value(tier);
  static Insertable<TrafficBucketRow> custom({
    Expression<int>? id,
    Expression<int>? hourMs,
    Expression<String>? module,
    Expression<String>? direction,
    Expression<String>? tier,
    Expression<String>? transport,
    Expression<int>? bytes,
    Expression<int>? samples,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (hourMs != null) 'hour_ms': hourMs,
      if (module != null) 'module': module,
      if (direction != null) 'direction': direction,
      if (tier != null) 'tier': tier,
      if (transport != null) 'transport': transport,
      if (bytes != null) 'bytes': bytes,
      if (samples != null) 'samples': samples,
    });
  }

  TrafficBucketsCompanion copyWith({
    Value<int>? id,
    Value<int>? hourMs,
    Value<String>? module,
    Value<String>? direction,
    Value<String>? tier,
    Value<String>? transport,
    Value<int>? bytes,
    Value<int>? samples,
  }) {
    return TrafficBucketsCompanion(
      id: id ?? this.id,
      hourMs: hourMs ?? this.hourMs,
      module: module ?? this.module,
      direction: direction ?? this.direction,
      tier: tier ?? this.tier,
      transport: transport ?? this.transport,
      bytes: bytes ?? this.bytes,
      samples: samples ?? this.samples,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (hourMs.present) {
      map['hour_ms'] = Variable<int>(hourMs.value);
    }
    if (module.present) {
      map['module'] = Variable<String>(module.value);
    }
    if (direction.present) {
      map['direction'] = Variable<String>(direction.value);
    }
    if (tier.present) {
      map['tier'] = Variable<String>(tier.value);
    }
    if (transport.present) {
      map['transport'] = Variable<String>(transport.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<int>(bytes.value);
    }
    if (samples.present) {
      map['samples'] = Variable<int>(samples.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TrafficBucketsCompanion(')
          ..write('id: $id, ')
          ..write('hourMs: $hourMs, ')
          ..write('module: $module, ')
          ..write('direction: $direction, ')
          ..write('tier: $tier, ')
          ..write('transport: $transport, ')
          ..write('bytes: $bytes, ')
          ..write('samples: $samples')
          ..write(')'))
        .toString();
  }
}

abstract class _$AnalyticsDatabase extends GeneratedDatabase {
  _$AnalyticsDatabase(QueryExecutor e) : super(e);
  $AnalyticsDatabaseManager get managers => $AnalyticsDatabaseManager(this);
  late final $UsageEventsTable usageEvents = $UsageEventsTable(this);
  late final $UsageInsightsTable usageInsights = $UsageInsightsTable(this);
  late final $AnalyticsMetaRowsTable analyticsMetaRows =
      $AnalyticsMetaRowsTable(this);
  late final $TrafficBucketsTable trafficBuckets = $TrafficBucketsTable(this);
  late final Index usageEventAt = Index(
    'usage_event_at',
    'CREATE INDEX usage_event_at ON usage_events (at_ms)',
  );
  late final Index trafficBucketHour = Index(
    'traffic_bucket_hour',
    'CREATE INDEX traffic_bucket_hour ON traffic_buckets (hour_ms)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    usageEvents,
    usageInsights,
    analyticsMetaRows,
    trafficBuckets,
    usageEventAt,
    trafficBucketHour,
  ];
}

typedef $$UsageEventsTableCreateCompanionBuilder =
    UsageEventsCompanion Function({
      Value<int> id,
      required int atMs,
      required String module,
      required String action,
      Value<String> object,
      Value<int> value,
      Value<String> detail,
      Value<String> session,
      Value<String> account,
    });
typedef $$UsageEventsTableUpdateCompanionBuilder =
    UsageEventsCompanion Function({
      Value<int> id,
      Value<int> atMs,
      Value<String> module,
      Value<String> action,
      Value<String> object,
      Value<int> value,
      Value<String> detail,
      Value<String> session,
      Value<String> account,
    });

class $$UsageEventsTableFilterComposer
    extends Composer<_$AnalyticsDatabase, $UsageEventsTable> {
  $$UsageEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get atMs => $composableBuilder(
    column: $table.atMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get module => $composableBuilder(
    column: $table.module,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get action => $composableBuilder(
    column: $table.action,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get object => $composableBuilder(
    column: $table.object,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get detail => $composableBuilder(
    column: $table.detail,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get session => $composableBuilder(
    column: $table.session,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get account => $composableBuilder(
    column: $table.account,
    builder: (column) => ColumnFilters(column),
  );
}

class $$UsageEventsTableOrderingComposer
    extends Composer<_$AnalyticsDatabase, $UsageEventsTable> {
  $$UsageEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get atMs => $composableBuilder(
    column: $table.atMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get module => $composableBuilder(
    column: $table.module,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get action => $composableBuilder(
    column: $table.action,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get object => $composableBuilder(
    column: $table.object,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get detail => $composableBuilder(
    column: $table.detail,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get session => $composableBuilder(
    column: $table.session,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get account => $composableBuilder(
    column: $table.account,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$UsageEventsTableAnnotationComposer
    extends Composer<_$AnalyticsDatabase, $UsageEventsTable> {
  $$UsageEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get atMs =>
      $composableBuilder(column: $table.atMs, builder: (column) => column);

  GeneratedColumn<String> get module =>
      $composableBuilder(column: $table.module, builder: (column) => column);

  GeneratedColumn<String> get action =>
      $composableBuilder(column: $table.action, builder: (column) => column);

  GeneratedColumn<String> get object =>
      $composableBuilder(column: $table.object, builder: (column) => column);

  GeneratedColumn<int> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);

  GeneratedColumn<String> get detail =>
      $composableBuilder(column: $table.detail, builder: (column) => column);

  GeneratedColumn<String> get session =>
      $composableBuilder(column: $table.session, builder: (column) => column);

  GeneratedColumn<String> get account =>
      $composableBuilder(column: $table.account, builder: (column) => column);
}

class $$UsageEventsTableTableManager
    extends
        RootTableManager<
          _$AnalyticsDatabase,
          $UsageEventsTable,
          UsageEventRow,
          $$UsageEventsTableFilterComposer,
          $$UsageEventsTableOrderingComposer,
          $$UsageEventsTableAnnotationComposer,
          $$UsageEventsTableCreateCompanionBuilder,
          $$UsageEventsTableUpdateCompanionBuilder,
          (
            UsageEventRow,
            BaseReferences<
              _$AnalyticsDatabase,
              $UsageEventsTable,
              UsageEventRow
            >,
          ),
          UsageEventRow,
          PrefetchHooks Function()
        > {
  $$UsageEventsTableTableManager(
    _$AnalyticsDatabase db,
    $UsageEventsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UsageEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UsageEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UsageEventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> atMs = const Value.absent(),
                Value<String> module = const Value.absent(),
                Value<String> action = const Value.absent(),
                Value<String> object = const Value.absent(),
                Value<int> value = const Value.absent(),
                Value<String> detail = const Value.absent(),
                Value<String> session = const Value.absent(),
                Value<String> account = const Value.absent(),
              }) => UsageEventsCompanion(
                id: id,
                atMs: atMs,
                module: module,
                action: action,
                object: object,
                value: value,
                detail: detail,
                session: session,
                account: account,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int atMs,
                required String module,
                required String action,
                Value<String> object = const Value.absent(),
                Value<int> value = const Value.absent(),
                Value<String> detail = const Value.absent(),
                Value<String> session = const Value.absent(),
                Value<String> account = const Value.absent(),
              }) => UsageEventsCompanion.insert(
                id: id,
                atMs: atMs,
                module: module,
                action: action,
                object: object,
                value: value,
                detail: detail,
                session: session,
                account: account,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$UsageEventsTable, UsageEventRow>(table),
                  BaseReferences<
                    _$AnalyticsDatabase,
                    $UsageEventsTable,
                    UsageEventRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$UsageEventsTableProcessedTableManager =
    ProcessedTableManager<
      _$AnalyticsDatabase,
      $UsageEventsTable,
      UsageEventRow,
      $$UsageEventsTableFilterComposer,
      $$UsageEventsTableOrderingComposer,
      $$UsageEventsTableAnnotationComposer,
      $$UsageEventsTableCreateCompanionBuilder,
      $$UsageEventsTableUpdateCompanionBuilder,
      (
        UsageEventRow,
        BaseReferences<_$AnalyticsDatabase, $UsageEventsTable, UsageEventRow>,
      ),
      UsageEventRow,
      PrefetchHooks Function()
    >;
typedef $$UsageInsightsTableCreateCompanionBuilder =
    UsageInsightsCompanion Function({
      Value<int> id,
      required int generatedAtMs,
      required String kind,
      required String title,
      required String body,
      Value<String> suggestion,
      Value<double> score,
      Value<String> evidence,
      Value<String> source,
      Value<String> model,
      Value<int> appliedAtMs,
    });
typedef $$UsageInsightsTableUpdateCompanionBuilder =
    UsageInsightsCompanion Function({
      Value<int> id,
      Value<int> generatedAtMs,
      Value<String> kind,
      Value<String> title,
      Value<String> body,
      Value<String> suggestion,
      Value<double> score,
      Value<String> evidence,
      Value<String> source,
      Value<String> model,
      Value<int> appliedAtMs,
    });

class $$UsageInsightsTableFilterComposer
    extends Composer<_$AnalyticsDatabase, $UsageInsightsTable> {
  $$UsageInsightsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get generatedAtMs => $composableBuilder(
    column: $table.generatedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get suggestion => $composableBuilder(
    column: $table.suggestion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get score => $composableBuilder(
    column: $table.score,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get evidence => $composableBuilder(
    column: $table.evidence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get appliedAtMs => $composableBuilder(
    column: $table.appliedAtMs,
    builder: (column) => ColumnFilters(column),
  );
}

class $$UsageInsightsTableOrderingComposer
    extends Composer<_$AnalyticsDatabase, $UsageInsightsTable> {
  $$UsageInsightsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get generatedAtMs => $composableBuilder(
    column: $table.generatedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get suggestion => $composableBuilder(
    column: $table.suggestion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get score => $composableBuilder(
    column: $table.score,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get evidence => $composableBuilder(
    column: $table.evidence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get appliedAtMs => $composableBuilder(
    column: $table.appliedAtMs,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$UsageInsightsTableAnnotationComposer
    extends Composer<_$AnalyticsDatabase, $UsageInsightsTable> {
  $$UsageInsightsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get generatedAtMs => $composableBuilder(
    column: $table.generatedAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get suggestion => $composableBuilder(
    column: $table.suggestion,
    builder: (column) => column,
  );

  GeneratedColumn<double> get score =>
      $composableBuilder(column: $table.score, builder: (column) => column);

  GeneratedColumn<String> get evidence =>
      $composableBuilder(column: $table.evidence, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<int> get appliedAtMs => $composableBuilder(
    column: $table.appliedAtMs,
    builder: (column) => column,
  );
}

class $$UsageInsightsTableTableManager
    extends
        RootTableManager<
          _$AnalyticsDatabase,
          $UsageInsightsTable,
          UsageInsightRow,
          $$UsageInsightsTableFilterComposer,
          $$UsageInsightsTableOrderingComposer,
          $$UsageInsightsTableAnnotationComposer,
          $$UsageInsightsTableCreateCompanionBuilder,
          $$UsageInsightsTableUpdateCompanionBuilder,
          (
            UsageInsightRow,
            BaseReferences<
              _$AnalyticsDatabase,
              $UsageInsightsTable,
              UsageInsightRow
            >,
          ),
          UsageInsightRow,
          PrefetchHooks Function()
        > {
  $$UsageInsightsTableTableManager(
    _$AnalyticsDatabase db,
    $UsageInsightsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UsageInsightsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UsageInsightsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UsageInsightsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> generatedAtMs = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<String> suggestion = const Value.absent(),
                Value<double> score = const Value.absent(),
                Value<String> evidence = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> model = const Value.absent(),
                Value<int> appliedAtMs = const Value.absent(),
              }) => UsageInsightsCompanion(
                id: id,
                generatedAtMs: generatedAtMs,
                kind: kind,
                title: title,
                body: body,
                suggestion: suggestion,
                score: score,
                evidence: evidence,
                source: source,
                model: model,
                appliedAtMs: appliedAtMs,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int generatedAtMs,
                required String kind,
                required String title,
                required String body,
                Value<String> suggestion = const Value.absent(),
                Value<double> score = const Value.absent(),
                Value<String> evidence = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String> model = const Value.absent(),
                Value<int> appliedAtMs = const Value.absent(),
              }) => UsageInsightsCompanion.insert(
                id: id,
                generatedAtMs: generatedAtMs,
                kind: kind,
                title: title,
                body: body,
                suggestion: suggestion,
                score: score,
                evidence: evidence,
                source: source,
                model: model,
                appliedAtMs: appliedAtMs,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$UsageInsightsTable, UsageInsightRow>(table),
                  BaseReferences<
                    _$AnalyticsDatabase,
                    $UsageInsightsTable,
                    UsageInsightRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$UsageInsightsTableProcessedTableManager =
    ProcessedTableManager<
      _$AnalyticsDatabase,
      $UsageInsightsTable,
      UsageInsightRow,
      $$UsageInsightsTableFilterComposer,
      $$UsageInsightsTableOrderingComposer,
      $$UsageInsightsTableAnnotationComposer,
      $$UsageInsightsTableCreateCompanionBuilder,
      $$UsageInsightsTableUpdateCompanionBuilder,
      (
        UsageInsightRow,
        BaseReferences<
          _$AnalyticsDatabase,
          $UsageInsightsTable,
          UsageInsightRow
        >,
      ),
      UsageInsightRow,
      PrefetchHooks Function()
    >;
typedef $$AnalyticsMetaRowsTableCreateCompanionBuilder =
    AnalyticsMetaRowsCompanion Function({
      required String key,
      Value<String> value,
      Value<int> rowid,
    });
typedef $$AnalyticsMetaRowsTableUpdateCompanionBuilder =
    AnalyticsMetaRowsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$AnalyticsMetaRowsTableFilterComposer
    extends Composer<_$AnalyticsDatabase, $AnalyticsMetaRowsTable> {
  $$AnalyticsMetaRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AnalyticsMetaRowsTableOrderingComposer
    extends Composer<_$AnalyticsDatabase, $AnalyticsMetaRowsTable> {
  $$AnalyticsMetaRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AnalyticsMetaRowsTableAnnotationComposer
    extends Composer<_$AnalyticsDatabase, $AnalyticsMetaRowsTable> {
  $$AnalyticsMetaRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$AnalyticsMetaRowsTableTableManager
    extends
        RootTableManager<
          _$AnalyticsDatabase,
          $AnalyticsMetaRowsTable,
          AnalyticsMetaRow,
          $$AnalyticsMetaRowsTableFilterComposer,
          $$AnalyticsMetaRowsTableOrderingComposer,
          $$AnalyticsMetaRowsTableAnnotationComposer,
          $$AnalyticsMetaRowsTableCreateCompanionBuilder,
          $$AnalyticsMetaRowsTableUpdateCompanionBuilder,
          (
            AnalyticsMetaRow,
            BaseReferences<
              _$AnalyticsDatabase,
              $AnalyticsMetaRowsTable,
              AnalyticsMetaRow
            >,
          ),
          AnalyticsMetaRow,
          PrefetchHooks Function()
        > {
  $$AnalyticsMetaRowsTableTableManager(
    _$AnalyticsDatabase db,
    $AnalyticsMetaRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AnalyticsMetaRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AnalyticsMetaRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AnalyticsMetaRowsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AnalyticsMetaRowsCompanion(
                key: key,
                value: value,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AnalyticsMetaRowsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AnalyticsMetaRowsTable, AnalyticsMetaRow>(table),
                  BaseReferences<
                    _$AnalyticsDatabase,
                    $AnalyticsMetaRowsTable,
                    AnalyticsMetaRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AnalyticsMetaRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AnalyticsDatabase,
      $AnalyticsMetaRowsTable,
      AnalyticsMetaRow,
      $$AnalyticsMetaRowsTableFilterComposer,
      $$AnalyticsMetaRowsTableOrderingComposer,
      $$AnalyticsMetaRowsTableAnnotationComposer,
      $$AnalyticsMetaRowsTableCreateCompanionBuilder,
      $$AnalyticsMetaRowsTableUpdateCompanionBuilder,
      (
        AnalyticsMetaRow,
        BaseReferences<
          _$AnalyticsDatabase,
          $AnalyticsMetaRowsTable,
          AnalyticsMetaRow
        >,
      ),
      AnalyticsMetaRow,
      PrefetchHooks Function()
    >;
typedef $$TrafficBucketsTableCreateCompanionBuilder =
    TrafficBucketsCompanion Function({
      Value<int> id,
      required int hourMs,
      required String module,
      required String direction,
      required String tier,
      Value<String> transport,
      Value<int> bytes,
      Value<int> samples,
    });
typedef $$TrafficBucketsTableUpdateCompanionBuilder =
    TrafficBucketsCompanion Function({
      Value<int> id,
      Value<int> hourMs,
      Value<String> module,
      Value<String> direction,
      Value<String> tier,
      Value<String> transport,
      Value<int> bytes,
      Value<int> samples,
    });

class $$TrafficBucketsTableFilterComposer
    extends Composer<_$AnalyticsDatabase, $TrafficBucketsTable> {
  $$TrafficBucketsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get hourMs => $composableBuilder(
    column: $table.hourMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get module => $composableBuilder(
    column: $table.module,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tier => $composableBuilder(
    column: $table.tier,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get transport => $composableBuilder(
    column: $table.transport,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get samples => $composableBuilder(
    column: $table.samples,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TrafficBucketsTableOrderingComposer
    extends Composer<_$AnalyticsDatabase, $TrafficBucketsTable> {
  $$TrafficBucketsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get hourMs => $composableBuilder(
    column: $table.hourMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get module => $composableBuilder(
    column: $table.module,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tier => $composableBuilder(
    column: $table.tier,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get transport => $composableBuilder(
    column: $table.transport,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get samples => $composableBuilder(
    column: $table.samples,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TrafficBucketsTableAnnotationComposer
    extends Composer<_$AnalyticsDatabase, $TrafficBucketsTable> {
  $$TrafficBucketsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get hourMs =>
      $composableBuilder(column: $table.hourMs, builder: (column) => column);

  GeneratedColumn<String> get module =>
      $composableBuilder(column: $table.module, builder: (column) => column);

  GeneratedColumn<String> get direction =>
      $composableBuilder(column: $table.direction, builder: (column) => column);

  GeneratedColumn<String> get tier =>
      $composableBuilder(column: $table.tier, builder: (column) => column);

  GeneratedColumn<String> get transport =>
      $composableBuilder(column: $table.transport, builder: (column) => column);

  GeneratedColumn<int> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<int> get samples =>
      $composableBuilder(column: $table.samples, builder: (column) => column);
}

class $$TrafficBucketsTableTableManager
    extends
        RootTableManager<
          _$AnalyticsDatabase,
          $TrafficBucketsTable,
          TrafficBucketRow,
          $$TrafficBucketsTableFilterComposer,
          $$TrafficBucketsTableOrderingComposer,
          $$TrafficBucketsTableAnnotationComposer,
          $$TrafficBucketsTableCreateCompanionBuilder,
          $$TrafficBucketsTableUpdateCompanionBuilder,
          (
            TrafficBucketRow,
            BaseReferences<
              _$AnalyticsDatabase,
              $TrafficBucketsTable,
              TrafficBucketRow
            >,
          ),
          TrafficBucketRow,
          PrefetchHooks Function()
        > {
  $$TrafficBucketsTableTableManager(
    _$AnalyticsDatabase db,
    $TrafficBucketsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TrafficBucketsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TrafficBucketsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TrafficBucketsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> hourMs = const Value.absent(),
                Value<String> module = const Value.absent(),
                Value<String> direction = const Value.absent(),
                Value<String> tier = const Value.absent(),
                Value<String> transport = const Value.absent(),
                Value<int> bytes = const Value.absent(),
                Value<int> samples = const Value.absent(),
              }) => TrafficBucketsCompanion(
                id: id,
                hourMs: hourMs,
                module: module,
                direction: direction,
                tier: tier,
                transport: transport,
                bytes: bytes,
                samples: samples,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int hourMs,
                required String module,
                required String direction,
                required String tier,
                Value<String> transport = const Value.absent(),
                Value<int> bytes = const Value.absent(),
                Value<int> samples = const Value.absent(),
              }) => TrafficBucketsCompanion.insert(
                id: id,
                hourMs: hourMs,
                module: module,
                direction: direction,
                tier: tier,
                transport: transport,
                bytes: bytes,
                samples: samples,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TrafficBucketsTable, TrafficBucketRow>(table),
                  BaseReferences<
                    _$AnalyticsDatabase,
                    $TrafficBucketsTable,
                    TrafficBucketRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TrafficBucketsTableProcessedTableManager =
    ProcessedTableManager<
      _$AnalyticsDatabase,
      $TrafficBucketsTable,
      TrafficBucketRow,
      $$TrafficBucketsTableFilterComposer,
      $$TrafficBucketsTableOrderingComposer,
      $$TrafficBucketsTableAnnotationComposer,
      $$TrafficBucketsTableCreateCompanionBuilder,
      $$TrafficBucketsTableUpdateCompanionBuilder,
      (
        TrafficBucketRow,
        BaseReferences<
          _$AnalyticsDatabase,
          $TrafficBucketsTable,
          TrafficBucketRow
        >,
      ),
      TrafficBucketRow,
      PrefetchHooks Function()
    >;

class $AnalyticsDatabaseManager {
  final _$AnalyticsDatabase _db;
  $AnalyticsDatabaseManager(this._db);
  $$UsageEventsTableTableManager get usageEvents =>
      $$UsageEventsTableTableManager(_db, _db.usageEvents);
  $$UsageInsightsTableTableManager get usageInsights =>
      $$UsageInsightsTableTableManager(_db, _db.usageInsights);
  $$AnalyticsMetaRowsTableTableManager get analyticsMetaRows =>
      $$AnalyticsMetaRowsTableTableManager(_db, _db.analyticsMetaRows);
  $$TrafficBucketsTableTableManager get trafficBuckets =>
      $$TrafficBucketsTableTableManager(_db, _db.trafficBuckets);
}
