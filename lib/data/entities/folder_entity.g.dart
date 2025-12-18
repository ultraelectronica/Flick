// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'folder_entity.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetFolderEntityCollection on Isar {
  IsarCollection<FolderEntity> get folderEntitys => this.collection();
}

const FolderEntitySchema = CollectionSchema(
  name: r'FolderEntity',
  id: 1865616643271602644,
  properties: {
    r'dateAdded': PropertySchema(
      id: 0,
      name: r'dateAdded',
      type: IsarType.dateTime,
    ),
    r'displayName': PropertySchema(
      id: 1,
      name: r'displayName',
      type: IsarType.string,
    ),
    r'lastScanned': PropertySchema(
      id: 2,
      name: r'lastScanned',
      type: IsarType.dateTime,
    ),
    r'songCount': PropertySchema(
      id: 3,
      name: r'songCount',
      type: IsarType.long,
    ),
    r'uri': PropertySchema(id: 4, name: r'uri', type: IsarType.string),
  },

  estimateSize: _folderEntityEstimateSize,
  serialize: _folderEntitySerialize,
  deserialize: _folderEntityDeserialize,
  deserializeProp: _folderEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'uri': IndexSchema(
      id: 8568316795971944889,
      name: r'uri',
      unique: true,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'uri',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},

  getId: _folderEntityGetId,
  getLinks: _folderEntityGetLinks,
  attach: _folderEntityAttach,
  version: '3.3.0',
);

int _folderEntityEstimateSize(
  FolderEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.displayName.length * 3;
  bytesCount += 3 + object.uri.length * 3;
  return bytesCount;
}

void _folderEntitySerialize(
  FolderEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeDateTime(offsets[0], object.dateAdded);
  writer.writeString(offsets[1], object.displayName);
  writer.writeDateTime(offsets[2], object.lastScanned);
  writer.writeLong(offsets[3], object.songCount);
  writer.writeString(offsets[4], object.uri);
}

FolderEntity _folderEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = FolderEntity();
  object.dateAdded = reader.readDateTime(offsets[0]);
  object.displayName = reader.readString(offsets[1]);
  object.id = id;
  object.lastScanned = reader.readDateTimeOrNull(offsets[2]);
  object.songCount = reader.readLong(offsets[3]);
  object.uri = reader.readString(offsets[4]);
  return object;
}

P _folderEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readDateTime(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 3:
      return (reader.readLong(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _folderEntityGetId(FolderEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _folderEntityGetLinks(FolderEntity object) {
  return [];
}

void _folderEntityAttach(
  IsarCollection<dynamic> col,
  Id id,
  FolderEntity object,
) {
  object.id = id;
}

extension FolderEntityByIndex on IsarCollection<FolderEntity> {
  Future<FolderEntity?> getByUri(String uri) {
    return getByIndex(r'uri', [uri]);
  }

  FolderEntity? getByUriSync(String uri) {
    return getByIndexSync(r'uri', [uri]);
  }

  Future<bool> deleteByUri(String uri) {
    return deleteByIndex(r'uri', [uri]);
  }

  bool deleteByUriSync(String uri) {
    return deleteByIndexSync(r'uri', [uri]);
  }

  Future<List<FolderEntity?>> getAllByUri(List<String> uriValues) {
    final values = uriValues.map((e) => [e]).toList();
    return getAllByIndex(r'uri', values);
  }

  List<FolderEntity?> getAllByUriSync(List<String> uriValues) {
    final values = uriValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'uri', values);
  }

  Future<int> deleteAllByUri(List<String> uriValues) {
    final values = uriValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'uri', values);
  }

  int deleteAllByUriSync(List<String> uriValues) {
    final values = uriValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'uri', values);
  }

  Future<Id> putByUri(FolderEntity object) {
    return putByIndex(r'uri', object);
  }

  Id putByUriSync(FolderEntity object, {bool saveLinks = true}) {
    return putByIndexSync(r'uri', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByUri(List<FolderEntity> objects) {
    return putAllByIndex(r'uri', objects);
  }

  List<Id> putAllByUriSync(
    List<FolderEntity> objects, {
    bool saveLinks = true,
  }) {
    return putAllByIndexSync(r'uri', objects, saveLinks: saveLinks);
  }
}

extension FolderEntityQueryWhereSort
    on QueryBuilder<FolderEntity, FolderEntity, QWhere> {
  QueryBuilder<FolderEntity, FolderEntity, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension FolderEntityQueryWhere
    on QueryBuilder<FolderEntity, FolderEntity, QWhereClause> {
  QueryBuilder<FolderEntity, FolderEntity, QAfterWhereClause> idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(lower: id, upper: id));
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterWhereClause> idNotEqualTo(
    Id id,
  ) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterWhereClause> idGreaterThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterWhereClause> idLessThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.between(
          lower: lowerId,
          includeLower: includeLower,
          upper: upperId,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterWhereClause> uriEqualTo(
    String uri,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'uri', value: [uri]),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterWhereClause> uriNotEqualTo(
    String uri,
  ) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'uri',
                lower: [],
                upper: [uri],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'uri',
                lower: [uri],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'uri',
                lower: [uri],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'uri',
                lower: [],
                upper: [uri],
                includeUpper: false,
              ),
            );
      }
    });
  }
}

extension FolderEntityQueryFilter
    on QueryBuilder<FolderEntity, FolderEntity, QFilterCondition> {
  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  dateAddedEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'dateAdded', value: value),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  dateAddedGreaterThan(DateTime value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'dateAdded',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  dateAddedLessThan(DateTime value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'dateAdded',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  dateAddedBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'dateAdded',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  displayNameEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'displayName',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  displayNameGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'displayName',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  displayNameLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'displayName',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  displayNameBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'displayName',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  displayNameStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'displayName',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  displayNameEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'displayName',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  displayNameContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'displayName',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  displayNameMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'displayName',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  displayNameIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'displayName', value: ''),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  displayNameIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'displayName', value: ''),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> idEqualTo(
    Id value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'id', value: value),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'id',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  lastScannedIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'lastScanned'),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  lastScannedIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'lastScanned'),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  lastScannedEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'lastScanned', value: value),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  lastScannedGreaterThan(DateTime? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'lastScanned',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  lastScannedLessThan(DateTime? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'lastScanned',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  lastScannedBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'lastScanned',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  songCountEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'songCount', value: value),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  songCountGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'songCount',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  songCountLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'songCount',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  songCountBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'songCount',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> uriEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'uri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  uriGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'uri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> uriLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'uri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> uriBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'uri',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> uriStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'uri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> uriEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'uri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> uriContains(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'uri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> uriMatches(
    String pattern, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'uri',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition> uriIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'uri', value: ''),
      );
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterFilterCondition>
  uriIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'uri', value: ''),
      );
    });
  }
}

extension FolderEntityQueryObject
    on QueryBuilder<FolderEntity, FolderEntity, QFilterCondition> {}

extension FolderEntityQueryLinks
    on QueryBuilder<FolderEntity, FolderEntity, QFilterCondition> {}

extension FolderEntityQuerySortBy
    on QueryBuilder<FolderEntity, FolderEntity, QSortBy> {
  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> sortByDateAdded() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateAdded', Sort.asc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> sortByDateAddedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateAdded', Sort.desc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> sortByDisplayName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'displayName', Sort.asc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy>
  sortByDisplayNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'displayName', Sort.desc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> sortByLastScanned() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastScanned', Sort.asc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy>
  sortByLastScannedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastScanned', Sort.desc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> sortBySongCount() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'songCount', Sort.asc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> sortBySongCountDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'songCount', Sort.desc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> sortByUri() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uri', Sort.asc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> sortByUriDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uri', Sort.desc);
    });
  }
}

extension FolderEntityQuerySortThenBy
    on QueryBuilder<FolderEntity, FolderEntity, QSortThenBy> {
  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> thenByDateAdded() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateAdded', Sort.asc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> thenByDateAddedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateAdded', Sort.desc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> thenByDisplayName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'displayName', Sort.asc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy>
  thenByDisplayNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'displayName', Sort.desc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> thenByLastScanned() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastScanned', Sort.asc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy>
  thenByLastScannedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastScanned', Sort.desc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> thenBySongCount() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'songCount', Sort.asc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> thenBySongCountDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'songCount', Sort.desc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> thenByUri() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uri', Sort.asc);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QAfterSortBy> thenByUriDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uri', Sort.desc);
    });
  }
}

extension FolderEntityQueryWhereDistinct
    on QueryBuilder<FolderEntity, FolderEntity, QDistinct> {
  QueryBuilder<FolderEntity, FolderEntity, QDistinct> distinctByDateAdded() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'dateAdded');
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QDistinct> distinctByDisplayName({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'displayName', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QDistinct> distinctByLastScanned() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'lastScanned');
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QDistinct> distinctBySongCount() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'songCount');
    });
  }

  QueryBuilder<FolderEntity, FolderEntity, QDistinct> distinctByUri({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'uri', caseSensitive: caseSensitive);
    });
  }
}

extension FolderEntityQueryProperty
    on QueryBuilder<FolderEntity, FolderEntity, QQueryProperty> {
  QueryBuilder<FolderEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<FolderEntity, DateTime, QQueryOperations> dateAddedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'dateAdded');
    });
  }

  QueryBuilder<FolderEntity, String, QQueryOperations> displayNameProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'displayName');
    });
  }

  QueryBuilder<FolderEntity, DateTime?, QQueryOperations>
  lastScannedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'lastScanned');
    });
  }

  QueryBuilder<FolderEntity, int, QQueryOperations> songCountProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'songCount');
    });
  }

  QueryBuilder<FolderEntity, String, QQueryOperations> uriProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'uri');
    });
  }
}
