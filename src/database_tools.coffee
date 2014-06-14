###
  backbone-sql.js 0.5.7
  Copyright (c) 2013 Vidigami - https://github.com/vidigami/backbone-sql
  License: MIT (http://www.opensource.org/licenses/mit-license.php)
###

_ = require 'underscore'
inflection = require 'inflection'
Knex = require 'knex'
Queue = require 'backbone-orm/lib/queue'
KNEX_COLUMN_OPERATORS = ['indexed', 'nullable', 'unique']
KNEX_COLUMN_OPTIONS = ['textType', 'length', 'precision', 'scale', 'value', 'values']

debounceCallback = (callback) ->
  return debounced_callback = -> return if debounced_callback.was_called; debounced_callback.was_called = true; callback.apply(null, Array.prototype.slice.call(arguments, 0))

module.exports = class DatabaseTools

  constructor: (@connection, @table_name, @schema, options={}) ->
    @strict = options.strict ? true
    @join_table_operations = []

  # Create and edit table methods create a knex table instance
  createTable: (callback) =>
    throw new Error "createTable requires a callback" unless _.isFunction(callback)

    callback = debounceCallback(callback)
    @connection.knex().schema.createTable(@table_name, (t) => callback(null, t)).exec(callback)
    return @

  editTable: (callback) =>
    throw new Error "editTable requires a callback" unless _.isFunction(callback)

    callback = debounceCallback(callback)
    @connection.knex().schema.table(@table_name, (t) => callback(null, t)).exec(callback)
    return @

  addField: (key, field, callback) =>
    type = "#{field.type[0].toLowerCase()}#{field.type.slice(1)}"
    @addColumn(key, type, field, callback)
    return @

  addColumn: (key, type, options={}, callback) =>
    @editTable (err, table) =>
      return callback(err) if err
      column_args = [key]

      # Assign column specific arguments
      constructor_options = _.pick(options, KNEX_COLUMN_OPTIONS)
      unless _.isEmpty(constructor_options)
        # Special case as they take two args
        if type in ['float', 'decimal']
          column_args[1] = constructor_options['precision']
          column_args[2] = constructor_options['scale']
        # Assume we've been given one valid argument
        else
          column_args[1] = _.values(constructor_options)[0]

      column = table[type].apply(table, column_args)
      column.primary() if options.primary
      column.notNullable() if options.nullable is false
      column.index() if options.indexed
      column.unique() if options.unique
      callback()

    return @

  addRelation: (key, relation, callback) =>
    return callback() if relation.isVirtual() # skip virtual
    if relation.type is 'belongsTo'
      @addColumn(relation.foreign_key, 'integer', ['nullable', 'index'], callback)
    else if relation.type is 'hasMany' and relation.reverse_relation.type is 'hasMany'
      @join_table_operations.push((callback) -> relation.findOrGenerateJoinTable().db().ensureSchema(callback))
    return @

  resetRelation: (key, relation, callback) =>
    return callback() if relation.isVirtual() # skip virtual
    if relation.type is 'belongsTo'
      @addColumn(relation.foreign_key, 'integer', ['nullable', 'index'], callback)
    else if relation.type is 'hasMany' and relation.reverse_relation.type is 'hasMany'
      @join_table_operations.push((callback) -> relation.findOrGenerateJoinTable().resetSchema(callback))
    return @

  resetSchema: (options, callback) =>
    [callback, options] = [options, {}] if arguments.length is 1

    @connection.knex().schema.dropTableIfExists(@table_name).exec (err) =>
      return callback(err) if err
      @ensureSchema(options, callback)

  # Ensure that the schema is reflected correctly in the database
  # Will create a table and add columns as required
  # Will not remove columns
  ensureSchema: (options, callback) =>
    [callback, options] = [options, {}] if arguments.length is 1

    return callback() if @ensuring
    @ensuring = true

    queue = new Queue(1)
    queue.defer (callback) =>
      @hasTable (err, table_exists) =>
        return callback(err) if err
        console.log "Ensuring table: #{@table_name} (exists: #{!!table_exists}) with fields: '#{_.keys(@schema.fields).join(', ')}' and relations: '#{_.keys(@schema.relations).join(', ')}'" if options.verbose
        return callback() if table_exists
        @createTable callback

    queue.defer (callback) => @ensureColumn('id', 'increments', {primary: true, indexed: true}, callback)

    for key, field of @schema.fields
      do (key, field) => queue.defer (callback) => @ensureField(key, field, callback)

    for key, relation of @schema.relations
      do (key, relation) => queue.defer (callback) => @ensureRelation(key, relation, callback)

    queue.await (err) =>
      @ensuring = false
      return callback(err) if err
      return callback() unless @join_table_operations.length

      queue = new Queue(1)
      for join_table_fn in @join_table_operations.splice(0, @join_table_operations.length)
        do (join_table_fn) => queue.defer (callback) => join_table_fn(callback)
      queue.await callback

  ensureRelation: (key, relation, callback) =>
    if relation.type is 'belongsTo'
      @hasColumn relation.foreign_key, (err, column_exists) =>
        return callback(err) if err
        if column_exists
          # TODO: update indices
          callback()
        else
          @addRelation(key, relation, callback)
    else if relation.type is 'hasMany' and relation.reverse_relation.type is 'hasMany'
      relation.findOrGenerateJoinTable().db().ensureSchema(callback)
    else
      callback()

  ensureField: (key, field, callback) =>
    @hasColumn key, (err, column_exists) =>
      return callback(err) if err
      if column_exists
        # TODO: update indices
        callback()
      else
        @addField(key, field, callback)

  ensureColumn: (key, type, options, callback) =>
    @hasColumn key, (err, column_exists) =>
      return callback(err) if err
      if column_exists
        # TODO: update indices
        callback()
      else
        @addColumn(key, type, options, callback)

  # knex method wrappers
  hasColumn: (column, callback) => @connection.knex().schema.hasColumn(@table_name, column).exec callback
  hasTable: (callback) => @connection.knex().schema.hasTable(@table_name).exec callback
  dropTable: (callback) => @connection.knex().schema.dropTable(@table_name).exec callback
  dropTableIfExists: (callback) => @connection.knex().schema.dropTableIfExists(@table_name).exec callback
  renameTable: (to, callback) => @connection.knex().schema.renameTable(@table_name, to).exec callback
