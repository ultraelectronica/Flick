// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'song_entity.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetSongEntityCollection on Isar {
  IsarCollection<SongEntity> get songEntitys => this.collection();
}

const SongEntitySchema = CollectionSchema(
  name: r'SongEntity',
  id: -4322515446108572550,
  properties: {
    r'album': PropertySchema(id: 0, name: r'album', type: IsarType.string),
    r'albumArtPath': PropertySchema(
      id: 1,
      name: r'albumArtPath',
      type: IsarType.string,
    ),
    r'albumArtist': PropertySchema(
      id: 2,
      name: r'albumArtist',
      type: IsarType.string,
    ),
    r'artist': PropertySchema(id: 3, name: r'artist', type: IsarType.string),
    r'bitDepth': PropertySchema(id: 4, name: r'bitDepth', type: IsarType.long),
    r'bitrate': PropertySchema(id: 5, name: r'bitrate', type: IsarType.long),
    r'channels': PropertySchema(id: 6, name: r'channels', type: IsarType.long),
    r'dateAdded': PropertySchema(
      id: 7,
      name: r'dateAdded',
      type: IsarType.dateTime,
    ),
    r'discNumber': PropertySchema(
      id: 8,
      name: r'discNumber',
      type: IsarType.long,
    ),
    r'durationMs': PropertySchema(
      id: 9,
      name: r'durationMs',
      type: IsarType.long,
    ),
    r'filePath': PropertySchema(
      id: 10,
      name: r'filePath',
      type: IsarType.string,
    ),
    r'fileSize': PropertySchema(id: 11, name: r'fileSize', type: IsarType.long),
    r'fileType': PropertySchema(
      id: 12,
      name: r'fileType',
      type: IsarType.string,
    ),
    r'folderUri': PropertySchema(
      id: 13,
      name: r'folderUri',
      type: IsarType.string,
    ),
    r'genre': PropertySchema(id: 14, name: r'genre', type: IsarType.string),
    r'lastModified': PropertySchema(
      id: 15,
      name: r'lastModified',
      type: IsarType.dateTime,
    ),
    r'sampleRate': PropertySchema(
      id: 16,
      name: r'sampleRate',
      type: IsarType.long,
    ),
    r'title': PropertySchema(id: 17, name: r'title', type: IsarType.string),
    r'trackNumber': PropertySchema(
      id: 18,
      name: r'trackNumber',
      type: IsarType.long,
    ),
    r'year': PropertySchema(id: 19, name: r'year', type: IsarType.long),
  },

  estimateSize: _songEntityEstimateSize,
  serialize: _songEntitySerialize,
  deserialize: _songEntityDeserialize,
  deserializeProp: _songEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'filePath': IndexSchema(
      id: 2918041768256347220,
      name: r'filePath',
      unique: true,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'filePath',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
    r'title': IndexSchema(
      id: -7636685945352118059,
      name: r'title',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'title',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
    r'artist': IndexSchema(
      id: 5842945185359817302,
      name: r'artist',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'artist',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
    r'album': IndexSchema(
      id: 6222745341035631462,
      name: r'album',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'album',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
    r'genre': IndexSchema(
      id: 7810252941268804523,
      name: r'genre',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'genre',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},

  getId: _songEntityGetId,
  getLinks: _songEntityGetLinks,
  attach: _songEntityAttach,
  version: '3.3.0',
);

int _songEntityEstimateSize(
  SongEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  {
    final value = object.album;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.albumArtPath;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.albumArtist;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.artist.length * 3;
  bytesCount += 3 + object.filePath.length * 3;
  {
    final value = object.fileType;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.folderUri;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.genre;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.title.length * 3;
  return bytesCount;
}

void _songEntitySerialize(
  SongEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.album);
  writer.writeString(offsets[1], object.albumArtPath);
  writer.writeString(offsets[2], object.albumArtist);
  writer.writeString(offsets[3], object.artist);
  writer.writeLong(offsets[4], object.bitDepth);
  writer.writeLong(offsets[5], object.bitrate);
  writer.writeLong(offsets[6], object.channels);
  writer.writeDateTime(offsets[7], object.dateAdded);
  writer.writeLong(offsets[8], object.discNumber);
  writer.writeLong(offsets[9], object.durationMs);
  writer.writeString(offsets[10], object.filePath);
  writer.writeLong(offsets[11], object.fileSize);
  writer.writeString(offsets[12], object.fileType);
  writer.writeString(offsets[13], object.folderUri);
  writer.writeString(offsets[14], object.genre);
  writer.writeDateTime(offsets[15], object.lastModified);
  writer.writeLong(offsets[16], object.sampleRate);
  writer.writeString(offsets[17], object.title);
  writer.writeLong(offsets[18], object.trackNumber);
  writer.writeLong(offsets[19], object.year);
}

SongEntity _songEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = SongEntity();
  object.album = reader.readStringOrNull(offsets[0]);
  object.albumArtPath = reader.readStringOrNull(offsets[1]);
  object.albumArtist = reader.readStringOrNull(offsets[2]);
  object.artist = reader.readString(offsets[3]);
  object.bitDepth = reader.readLongOrNull(offsets[4]);
  object.bitrate = reader.readLongOrNull(offsets[5]);
  object.channels = reader.readLongOrNull(offsets[6]);
  object.dateAdded = reader.readDateTime(offsets[7]);
  object.discNumber = reader.readLongOrNull(offsets[8]);
  object.durationMs = reader.readLongOrNull(offsets[9]);
  object.filePath = reader.readString(offsets[10]);
  object.fileSize = reader.readLongOrNull(offsets[11]);
  object.fileType = reader.readStringOrNull(offsets[12]);
  object.folderUri = reader.readStringOrNull(offsets[13]);
  object.genre = reader.readStringOrNull(offsets[14]);
  object.id = id;
  object.lastModified = reader.readDateTimeOrNull(offsets[15]);
  object.sampleRate = reader.readLongOrNull(offsets[16]);
  object.title = reader.readString(offsets[17]);
  object.trackNumber = reader.readLongOrNull(offsets[18]);
  object.year = reader.readLongOrNull(offsets[19]);
  return object;
}

P _songEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readStringOrNull(offset)) as P;
    case 1:
      return (reader.readStringOrNull(offset)) as P;
    case 2:
      return (reader.readStringOrNull(offset)) as P;
    case 3:
      return (reader.readString(offset)) as P;
    case 4:
      return (reader.readLongOrNull(offset)) as P;
    case 5:
      return (reader.readLongOrNull(offset)) as P;
    case 6:
      return (reader.readLongOrNull(offset)) as P;
    case 7:
      return (reader.readDateTime(offset)) as P;
    case 8:
      return (reader.readLongOrNull(offset)) as P;
    case 9:
      return (reader.readLongOrNull(offset)) as P;
    case 10:
      return (reader.readString(offset)) as P;
    case 11:
      return (reader.readLongOrNull(offset)) as P;
    case 12:
      return (reader.readStringOrNull(offset)) as P;
    case 13:
      return (reader.readStringOrNull(offset)) as P;
    case 14:
      return (reader.readStringOrNull(offset)) as P;
    case 15:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 16:
      return (reader.readLongOrNull(offset)) as P;
    case 17:
      return (reader.readString(offset)) as P;
    case 18:
      return (reader.readLongOrNull(offset)) as P;
    case 19:
      return (reader.readLongOrNull(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _songEntityGetId(SongEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _songEntityGetLinks(SongEntity object) {
  return [];
}

void _songEntityAttach(IsarCollection<dynamic> col, Id id, SongEntity object) {
  object.id = id;
}

extension SongEntityByIndex on IsarCollection<SongEntity> {
  Future<SongEntity?> getByFilePath(String filePath) {
    return getByIndex(r'filePath', [filePath]);
  }

  SongEntity? getByFilePathSync(String filePath) {
    return getByIndexSync(r'filePath', [filePath]);
  }

  Future<bool> deleteByFilePath(String filePath) {
    return deleteByIndex(r'filePath', [filePath]);
  }

  bool deleteByFilePathSync(String filePath) {
    return deleteByIndexSync(r'filePath', [filePath]);
  }

  Future<List<SongEntity?>> getAllByFilePath(List<String> filePathValues) {
    final values = filePathValues.map((e) => [e]).toList();
    return getAllByIndex(r'filePath', values);
  }

  List<SongEntity?> getAllByFilePathSync(List<String> filePathValues) {
    final values = filePathValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'filePath', values);
  }

  Future<int> deleteAllByFilePath(List<String> filePathValues) {
    final values = filePathValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'filePath', values);
  }

  int deleteAllByFilePathSync(List<String> filePathValues) {
    final values = filePathValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'filePath', values);
  }

  Future<Id> putByFilePath(SongEntity object) {
    return putByIndex(r'filePath', object);
  }

  Id putByFilePathSync(SongEntity object, {bool saveLinks = true}) {
    return putByIndexSync(r'filePath', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByFilePath(List<SongEntity> objects) {
    return putAllByIndex(r'filePath', objects);
  }

  List<Id> putAllByFilePathSync(
    List<SongEntity> objects, {
    bool saveLinks = true,
  }) {
    return putAllByIndexSync(r'filePath', objects, saveLinks: saveLinks);
  }
}

extension SongEntityQueryWhereSort
    on QueryBuilder<SongEntity, SongEntity, QWhere> {
  QueryBuilder<SongEntity, SongEntity, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension SongEntityQueryWhere
    on QueryBuilder<SongEntity, SongEntity, QWhereClause> {
  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(lower: id, upper: id));
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> idNotEqualTo(Id id) {
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

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> idGreaterThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> idLessThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> idBetween(
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

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> filePathEqualTo(
    String filePath,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'filePath', value: [filePath]),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> filePathNotEqualTo(
    String filePath,
  ) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'filePath',
                lower: [],
                upper: [filePath],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'filePath',
                lower: [filePath],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'filePath',
                lower: [filePath],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'filePath',
                lower: [],
                upper: [filePath],
                includeUpper: false,
              ),
            );
      }
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> titleEqualTo(
    String title,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'title', value: [title]),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> titleNotEqualTo(
    String title,
  ) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'title',
                lower: [],
                upper: [title],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'title',
                lower: [title],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'title',
                lower: [title],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'title',
                lower: [],
                upper: [title],
                includeUpper: false,
              ),
            );
      }
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> artistEqualTo(
    String artist,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'artist', value: [artist]),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> artistNotEqualTo(
    String artist,
  ) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'artist',
                lower: [],
                upper: [artist],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'artist',
                lower: [artist],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'artist',
                lower: [artist],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'artist',
                lower: [],
                upper: [artist],
                includeUpper: false,
              ),
            );
      }
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> albumIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'album', value: [null]),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> albumIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.between(
          indexName: r'album',
          lower: [null],
          includeLower: false,
          upper: [],
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> albumEqualTo(
    String? album,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'album', value: [album]),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> albumNotEqualTo(
    String? album,
  ) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'album',
                lower: [],
                upper: [album],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'album',
                lower: [album],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'album',
                lower: [album],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'album',
                lower: [],
                upper: [album],
                includeUpper: false,
              ),
            );
      }
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> genreIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'genre', value: [null]),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> genreIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.between(
          indexName: r'genre',
          lower: [null],
          includeLower: false,
          upper: [],
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> genreEqualTo(
    String? genre,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'genre', value: [genre]),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterWhereClause> genreNotEqualTo(
    String? genre,
  ) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'genre',
                lower: [],
                upper: [genre],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'genre',
                lower: [genre],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'genre',
                lower: [genre],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'genre',
                lower: [],
                upper: [genre],
                includeUpper: false,
              ),
            );
      }
    });
  }
}

extension SongEntityQueryFilter
    on QueryBuilder<SongEntity, SongEntity, QFilterCondition> {
  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> albumIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'album'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> albumIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'album'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> albumEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'album',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> albumGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'album',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> albumLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'album',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> albumBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'album',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> albumStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'album',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> albumEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'album',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> albumContains(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'album',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> albumMatches(
    String pattern, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'album',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> albumIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'album', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'album', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'albumArtPath'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'albumArtPath'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'albumArtPath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'albumArtPath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'albumArtPath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'albumArtPath',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'albumArtPath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'albumArtPath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'albumArtPath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'albumArtPath',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'albumArtPath', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtPathIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'albumArtPath', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'albumArtist'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'albumArtist'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'albumArtist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'albumArtist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'albumArtist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'albumArtist',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'albumArtist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'albumArtist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'albumArtist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'albumArtist',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'albumArtist', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  albumArtistIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'albumArtist', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> artistEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'artist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> artistGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'artist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> artistLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'artist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> artistBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'artist',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> artistStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'artist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> artistEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'artist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> artistContains(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'artist',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> artistMatches(
    String pattern, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'artist',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> artistIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'artist', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  artistIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'artist', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> bitDepthIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'bitDepth'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  bitDepthIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'bitDepth'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> bitDepthEqualTo(
    int? value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'bitDepth', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  bitDepthGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'bitDepth',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> bitDepthLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'bitDepth',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> bitDepthBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'bitDepth',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> bitrateIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'bitrate'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  bitrateIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'bitrate'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> bitrateEqualTo(
    int? value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'bitrate', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  bitrateGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'bitrate',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> bitrateLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'bitrate',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> bitrateBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'bitrate',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> channelsIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'channels'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  channelsIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'channels'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> channelsEqualTo(
    int? value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'channels', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  channelsGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'channels',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> channelsLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'channels',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> channelsBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'channels',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> dateAddedEqualTo(
    DateTime value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'dateAdded', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
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

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> dateAddedLessThan(
    DateTime value, {
    bool include = false,
  }) {
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

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> dateAddedBetween(
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

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  discNumberIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'discNumber'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  discNumberIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'discNumber'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> discNumberEqualTo(
    int? value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'discNumber', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  discNumberGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'discNumber',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  discNumberLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'discNumber',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> discNumberBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'discNumber',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  durationMsIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'durationMs'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  durationMsIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'durationMs'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> durationMsEqualTo(
    int? value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'durationMs', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  durationMsGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'durationMs',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  durationMsLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'durationMs',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> durationMsBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'durationMs',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> filePathEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  filePathGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> filePathLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> filePathBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'filePath',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  filePathStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> filePathEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> filePathContains(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'filePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> filePathMatches(
    String pattern, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'filePath',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  filePathIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'filePath', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  filePathIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'filePath', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> fileSizeIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'fileSize'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  fileSizeIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'fileSize'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> fileSizeEqualTo(
    int? value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'fileSize', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  fileSizeGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'fileSize',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> fileSizeLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'fileSize',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> fileSizeBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'fileSize',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> fileTypeIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'fileType'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  fileTypeIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'fileType'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> fileTypeEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'fileType',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  fileTypeGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'fileType',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> fileTypeLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'fileType',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> fileTypeBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'fileType',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  fileTypeStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'fileType',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> fileTypeEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'fileType',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> fileTypeContains(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'fileType',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> fileTypeMatches(
    String pattern, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'fileType',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  fileTypeIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'fileType', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  fileTypeIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'fileType', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  folderUriIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'folderUri'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  folderUriIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'folderUri'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> folderUriEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'folderUri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  folderUriGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'folderUri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> folderUriLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'folderUri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> folderUriBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'folderUri',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  folderUriStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'folderUri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> folderUriEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'folderUri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> folderUriContains(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'folderUri',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> folderUriMatches(
    String pattern, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'folderUri',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  folderUriIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'folderUri', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  folderUriIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'folderUri', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> genreIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'genre'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> genreIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'genre'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> genreEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'genre',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> genreGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'genre',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> genreLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'genre',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> genreBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'genre',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> genreStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'genre',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> genreEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'genre',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> genreContains(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'genre',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> genreMatches(
    String pattern, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'genre',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> genreIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'genre', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  genreIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'genre', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> idEqualTo(
    Id value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'id', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> idGreaterThan(
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

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> idLessThan(
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

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> idBetween(
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

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  lastModifiedIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'lastModified'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  lastModifiedIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'lastModified'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  lastModifiedEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'lastModified', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  lastModifiedGreaterThan(DateTime? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'lastModified',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  lastModifiedLessThan(DateTime? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'lastModified',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  lastModifiedBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'lastModified',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  sampleRateIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'sampleRate'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  sampleRateIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'sampleRate'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> sampleRateEqualTo(
    int? value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'sampleRate', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  sampleRateGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'sampleRate',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  sampleRateLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'sampleRate',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> sampleRateBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'sampleRate',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> titleEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> titleGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> titleLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> titleBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'title',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> titleStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> titleEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> titleContains(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'title',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> titleMatches(
    String pattern, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'title',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> titleIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'title', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  titleIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'title', value: ''),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  trackNumberIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'trackNumber'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  trackNumberIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'trackNumber'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  trackNumberEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'trackNumber', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  trackNumberGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'trackNumber',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  trackNumberLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'trackNumber',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition>
  trackNumberBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'trackNumber',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> yearIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'year'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> yearIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'year'),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> yearEqualTo(
    int? value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'year', value: value),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> yearGreaterThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'year',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> yearLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'year',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterFilterCondition> yearBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'year',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }
}

extension SongEntityQueryObject
    on QueryBuilder<SongEntity, SongEntity, QFilterCondition> {}

extension SongEntityQueryLinks
    on QueryBuilder<SongEntity, SongEntity, QFilterCondition> {}

extension SongEntityQuerySortBy
    on QueryBuilder<SongEntity, SongEntity, QSortBy> {
  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByAlbum() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'album', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByAlbumDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'album', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByAlbumArtPath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'albumArtPath', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByAlbumArtPathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'albumArtPath', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByAlbumArtist() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'albumArtist', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByAlbumArtistDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'albumArtist', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByArtist() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'artist', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByArtistDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'artist', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByBitDepth() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bitDepth', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByBitDepthDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bitDepth', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByBitrate() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bitrate', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByBitrateDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bitrate', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByChannels() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'channels', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByChannelsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'channels', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByDateAdded() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateAdded', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByDateAddedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateAdded', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByDiscNumber() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'discNumber', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByDiscNumberDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'discNumber', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByDurationMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'durationMs', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByDurationMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'durationMs', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByFilePath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'filePath', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByFilePathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'filePath', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByFileSize() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fileSize', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByFileSizeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fileSize', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByFileType() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fileType', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByFileTypeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fileType', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByFolderUri() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'folderUri', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByFolderUriDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'folderUri', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByGenre() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'genre', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByGenreDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'genre', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByLastModified() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastModified', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByLastModifiedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastModified', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortBySampleRate() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sampleRate', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortBySampleRateDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sampleRate', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByTitle() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByTitleDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByTrackNumber() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'trackNumber', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByTrackNumberDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'trackNumber', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByYear() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'year', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> sortByYearDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'year', Sort.desc);
    });
  }
}

extension SongEntityQuerySortThenBy
    on QueryBuilder<SongEntity, SongEntity, QSortThenBy> {
  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByAlbum() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'album', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByAlbumDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'album', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByAlbumArtPath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'albumArtPath', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByAlbumArtPathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'albumArtPath', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByAlbumArtist() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'albumArtist', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByAlbumArtistDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'albumArtist', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByArtist() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'artist', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByArtistDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'artist', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByBitDepth() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bitDepth', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByBitDepthDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bitDepth', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByBitrate() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bitrate', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByBitrateDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bitrate', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByChannels() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'channels', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByChannelsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'channels', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByDateAdded() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateAdded', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByDateAddedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateAdded', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByDiscNumber() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'discNumber', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByDiscNumberDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'discNumber', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByDurationMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'durationMs', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByDurationMsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'durationMs', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByFilePath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'filePath', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByFilePathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'filePath', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByFileSize() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fileSize', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByFileSizeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fileSize', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByFileType() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fileType', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByFileTypeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fileType', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByFolderUri() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'folderUri', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByFolderUriDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'folderUri', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByGenre() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'genre', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByGenreDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'genre', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByLastModified() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastModified', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByLastModifiedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastModified', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenBySampleRate() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sampleRate', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenBySampleRateDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sampleRate', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByTitle() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByTitleDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'title', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByTrackNumber() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'trackNumber', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByTrackNumberDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'trackNumber', Sort.desc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByYear() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'year', Sort.asc);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QAfterSortBy> thenByYearDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'year', Sort.desc);
    });
  }
}

extension SongEntityQueryWhereDistinct
    on QueryBuilder<SongEntity, SongEntity, QDistinct> {
  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByAlbum({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'album', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByAlbumArtPath({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'albumArtPath', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByAlbumArtist({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'albumArtist', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByArtist({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'artist', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByBitDepth() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'bitDepth');
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByBitrate() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'bitrate');
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByChannels() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'channels');
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByDateAdded() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'dateAdded');
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByDiscNumber() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'discNumber');
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByDurationMs() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'durationMs');
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByFilePath({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'filePath', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByFileSize() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'fileSize');
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByFileType({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'fileType', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByFolderUri({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'folderUri', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByGenre({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'genre', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByLastModified() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'lastModified');
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctBySampleRate() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'sampleRate');
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByTitle({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'title', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByTrackNumber() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'trackNumber');
    });
  }

  QueryBuilder<SongEntity, SongEntity, QDistinct> distinctByYear() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'year');
    });
  }
}

extension SongEntityQueryProperty
    on QueryBuilder<SongEntity, SongEntity, QQueryProperty> {
  QueryBuilder<SongEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<SongEntity, String?, QQueryOperations> albumProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'album');
    });
  }

  QueryBuilder<SongEntity, String?, QQueryOperations> albumArtPathProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'albumArtPath');
    });
  }

  QueryBuilder<SongEntity, String?, QQueryOperations> albumArtistProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'albumArtist');
    });
  }

  QueryBuilder<SongEntity, String, QQueryOperations> artistProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'artist');
    });
  }

  QueryBuilder<SongEntity, int?, QQueryOperations> bitDepthProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'bitDepth');
    });
  }

  QueryBuilder<SongEntity, int?, QQueryOperations> bitrateProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'bitrate');
    });
  }

  QueryBuilder<SongEntity, int?, QQueryOperations> channelsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'channels');
    });
  }

  QueryBuilder<SongEntity, DateTime, QQueryOperations> dateAddedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'dateAdded');
    });
  }

  QueryBuilder<SongEntity, int?, QQueryOperations> discNumberProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'discNumber');
    });
  }

  QueryBuilder<SongEntity, int?, QQueryOperations> durationMsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'durationMs');
    });
  }

  QueryBuilder<SongEntity, String, QQueryOperations> filePathProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'filePath');
    });
  }

  QueryBuilder<SongEntity, int?, QQueryOperations> fileSizeProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'fileSize');
    });
  }

  QueryBuilder<SongEntity, String?, QQueryOperations> fileTypeProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'fileType');
    });
  }

  QueryBuilder<SongEntity, String?, QQueryOperations> folderUriProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'folderUri');
    });
  }

  QueryBuilder<SongEntity, String?, QQueryOperations> genreProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'genre');
    });
  }

  QueryBuilder<SongEntity, DateTime?, QQueryOperations> lastModifiedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'lastModified');
    });
  }

  QueryBuilder<SongEntity, int?, QQueryOperations> sampleRateProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'sampleRate');
    });
  }

  QueryBuilder<SongEntity, String, QQueryOperations> titleProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'title');
    });
  }

  QueryBuilder<SongEntity, int?, QQueryOperations> trackNumberProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'trackNumber');
    });
  }

  QueryBuilder<SongEntity, int?, QQueryOperations> yearProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'year');
    });
  }
}
