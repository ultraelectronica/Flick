// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'recently_played_entity.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetRecentlyPlayedEntityCollection on Isar {
  IsarCollection<RecentlyPlayedEntity> get recentlyPlayedEntitys =>
      this.collection();
}

const RecentlyPlayedEntitySchema = CollectionSchema(
  name: r'RecentlyPlayedEntity',
  id: 2313323638749217169,
  properties: {
    r'playedAt': PropertySchema(
      id: 0,
      name: r'playedAt',
      type: IsarType.dateTime,
    ),
    r'songId': PropertySchema(id: 1, name: r'songId', type: IsarType.long),
  },

  estimateSize: _recentlyPlayedEntityEstimateSize,
  serialize: _recentlyPlayedEntitySerialize,
  deserialize: _recentlyPlayedEntityDeserialize,
  deserializeProp: _recentlyPlayedEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'songId': IndexSchema(
      id: -4588889454650216128,
      name: r'songId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'songId',
          type: IndexType.value,
          caseSensitive: false,
        ),
      ],
    ),
    r'playedAt': IndexSchema(
      id: -3711549563919110219,
      name: r'playedAt',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'playedAt',
          type: IndexType.value,
          caseSensitive: false,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},

  getId: _recentlyPlayedEntityGetId,
  getLinks: _recentlyPlayedEntityGetLinks,
  attach: _recentlyPlayedEntityAttach,
  version: '3.3.0',
);

int _recentlyPlayedEntityEstimateSize(
  RecentlyPlayedEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  return bytesCount;
}

void _recentlyPlayedEntitySerialize(
  RecentlyPlayedEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeDateTime(offsets[0], object.playedAt);
  writer.writeLong(offsets[1], object.songId);
}

RecentlyPlayedEntity _recentlyPlayedEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = RecentlyPlayedEntity();
  object.id = id;
  object.playedAt = reader.readDateTime(offsets[0]);
  object.songId = reader.readLong(offsets[1]);
  return object;
}

P _recentlyPlayedEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readDateTime(offset)) as P;
    case 1:
      return (reader.readLong(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _recentlyPlayedEntityGetId(RecentlyPlayedEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _recentlyPlayedEntityGetLinks(
  RecentlyPlayedEntity object,
) {
  return [];
}

void _recentlyPlayedEntityAttach(
  IsarCollection<dynamic> col,
  Id id,
  RecentlyPlayedEntity object,
) {
  object.id = id;
}

extension RecentlyPlayedEntityQueryWhereSort
    on QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QWhere> {
  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhere>
  anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhere>
  anySongId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'songId'),
      );
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhere>
  anyPlayedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'playedAt'),
      );
    });
  }
}

extension RecentlyPlayedEntityQueryWhere
    on QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QWhereClause> {
  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(lower: id, upper: id));
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  idNotEqualTo(Id id) {
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

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  idBetween(
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

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  songIdEqualTo(int songId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'songId', value: [songId]),
      );
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  songIdNotEqualTo(int songId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'songId',
                lower: [],
                upper: [songId],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'songId',
                lower: [songId],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'songId',
                lower: [songId],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'songId',
                lower: [],
                upper: [songId],
                includeUpper: false,
              ),
            );
      }
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  songIdGreaterThan(int songId, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.between(
          indexName: r'songId',
          lower: [songId],
          includeLower: include,
          upper: [],
        ),
      );
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  songIdLessThan(int songId, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.between(
          indexName: r'songId',
          lower: [],
          upper: [songId],
          includeUpper: include,
        ),
      );
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  songIdBetween(
    int lowerSongId,
    int upperSongId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.between(
          indexName: r'songId',
          lower: [lowerSongId],
          includeLower: includeLower,
          upper: [upperSongId],
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  playedAtEqualTo(DateTime playedAt) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'playedAt', value: [playedAt]),
      );
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  playedAtNotEqualTo(DateTime playedAt) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'playedAt',
                lower: [],
                upper: [playedAt],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'playedAt',
                lower: [playedAt],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'playedAt',
                lower: [playedAt],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'playedAt',
                lower: [],
                upper: [playedAt],
                includeUpper: false,
              ),
            );
      }
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  playedAtGreaterThan(DateTime playedAt, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.between(
          indexName: r'playedAt',
          lower: [playedAt],
          includeLower: include,
          upper: [],
        ),
      );
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  playedAtLessThan(DateTime playedAt, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.between(
          indexName: r'playedAt',
          lower: [],
          upper: [playedAt],
          includeUpper: include,
        ),
      );
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterWhereClause>
  playedAtBetween(
    DateTime lowerPlayedAt,
    DateTime upperPlayedAt, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.between(
          indexName: r'playedAt',
          lower: [lowerPlayedAt],
          includeLower: includeLower,
          upper: [upperPlayedAt],
          includeUpper: includeUpper,
        ),
      );
    });
  }
}

extension RecentlyPlayedEntityQueryFilter
    on
        QueryBuilder<
          RecentlyPlayedEntity,
          RecentlyPlayedEntity,
          QFilterCondition
        > {
  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'id', value: value),
      );
    });
  }

  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  idGreaterThan(Id value, {bool include = false}) {
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

  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  idLessThan(Id value, {bool include = false}) {
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

  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  idBetween(
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

  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  playedAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'playedAt', value: value),
      );
    });
  }

  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  playedAtGreaterThan(DateTime value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'playedAt',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  playedAtLessThan(DateTime value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'playedAt',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  playedAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'playedAt',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  songIdEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'songId', value: value),
      );
    });
  }

  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  songIdGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'songId',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  songIdLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'songId',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    RecentlyPlayedEntity,
    RecentlyPlayedEntity,
    QAfterFilterCondition
  >
  songIdBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'songId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }
}

extension RecentlyPlayedEntityQueryObject
    on
        QueryBuilder<
          RecentlyPlayedEntity,
          RecentlyPlayedEntity,
          QFilterCondition
        > {}

extension RecentlyPlayedEntityQueryLinks
    on
        QueryBuilder<
          RecentlyPlayedEntity,
          RecentlyPlayedEntity,
          QFilterCondition
        > {}

extension RecentlyPlayedEntityQuerySortBy
    on QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QSortBy> {
  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterSortBy>
  sortByPlayedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'playedAt', Sort.asc);
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterSortBy>
  sortByPlayedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'playedAt', Sort.desc);
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterSortBy>
  sortBySongId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'songId', Sort.asc);
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterSortBy>
  sortBySongIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'songId', Sort.desc);
    });
  }
}

extension RecentlyPlayedEntityQuerySortThenBy
    on QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QSortThenBy> {
  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterSortBy>
  thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterSortBy>
  thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterSortBy>
  thenByPlayedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'playedAt', Sort.asc);
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterSortBy>
  thenByPlayedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'playedAt', Sort.desc);
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterSortBy>
  thenBySongId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'songId', Sort.asc);
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QAfterSortBy>
  thenBySongIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'songId', Sort.desc);
    });
  }
}

extension RecentlyPlayedEntityQueryWhereDistinct
    on QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QDistinct> {
  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QDistinct>
  distinctByPlayedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'playedAt');
    });
  }

  QueryBuilder<RecentlyPlayedEntity, RecentlyPlayedEntity, QDistinct>
  distinctBySongId() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'songId');
    });
  }
}

extension RecentlyPlayedEntityQueryProperty
    on
        QueryBuilder<
          RecentlyPlayedEntity,
          RecentlyPlayedEntity,
          QQueryProperty
        > {
  QueryBuilder<RecentlyPlayedEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<RecentlyPlayedEntity, DateTime, QQueryOperations>
  playedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'playedAt');
    });
  }

  QueryBuilder<RecentlyPlayedEntity, int, QQueryOperations> songIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'songId');
    });
  }
}
