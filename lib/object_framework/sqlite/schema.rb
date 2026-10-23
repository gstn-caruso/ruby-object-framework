# frozen_string_literal: true

module ObjectFramework
  module SQLite
    ForeignKey = Data.define(:table, :column, :target)
    Migration = Data.define(:version, :actions)

    class Schema
      TYPES = { string: "TEXT", integer: "INTEGER", float: "REAL", boolean: "INTEGER", blob: "BLOB" }.freeze
      attr_reader :tables, :foreign_keys, :migrations

      def self.from_mappings(mappings)
        mappings.validate!
        keys = mappings.flat_map do |mapping|
          mapping.associations.select { |item| item.kind == :belongs_to }.map do |association|
            ForeignKey.new(table: mapping.table, column: association.foreign_key, target: mappings.fetch(association.target).table)
          end
        end
        new(tables: mappings.to_h { |mapping| [mapping.table, mapping.schema] }, foreign_keys: keys)
      end

      def initialize(tables:, foreign_keys: [])
        @tables = tables.to_h do |name, columns|
          fields = columns.to_h { |column, type| [identifier(column), validate_type(type)] }
          raise ConfigurationError, "SQLite tables require a string id" unless fields[:id] == :string
          [identifier(name), fields]
        end
        @foreign_keys = foreign_keys.dup.freeze
        @initial_tables = @tables.transform_values { |columns| columns.dup.freeze }.freeze
        @migrations = [Migration.new(version: 1, actions: [].freeze)]
      end

      def migration(version, &declaration)
        raise ConfigurationError, "Schema is finalized" if frozen?
        raise ConfigurationError, "Migration versions must be consecutive" unless version == @migrations.last.version + 1
        editor = Editor.new(self)
        editor.instance_eval(&declaration)
        @migrations << Migration.new(version:, actions: editor.actions.each(&:freeze).freeze)
        self
      end

      def version; @migrations.last.version; end

      def table(name)
        @tables.fetch(identifier(name)) { raise ConfigurationError, "Unregistered SQLite table" }
      end

      def type(table_name, column)
        table(table_name).fetch(identifier(column)) { raise ConfigurationError, "Unregistered SQLite column" }
      end

      def quote(name); '"' + identifier(name).to_s + '"'; end
      def identifier(name); Persistence::Query.identifier(name); end

      def validate_type(type)
        raise ConfigurationError, "Unknown SQLite field type" unless TYPES.key?(type)
        type
      end

      def finalize!
        return self if frozen?
        foreign_keys.each { |key| type(key.table, key.column); type(key.target, :id) }
        @tables.each_value(&:freeze)
        @tables.freeze
        @migrations.freeze
        freeze
      end

      def create_statements
        @initial_tables.map do |name, columns|
          fields = columns.map do |column, type|
            "#{quote(column)} #{TYPES.fetch(type)}#{column == :id ? ' PRIMARY KEY NOT NULL' : ''}"
          end
          foreign_keys.select { |key| key.table == name }.each do |key|
            fields << "FOREIGN KEY (#{quote(key.column)}) REFERENCES #{quote(key.target)} (\"id\") DEFERRABLE INITIALLY DEFERRED"
          end
          "CREATE TABLE #{quote(name)} (#{fields.join(', ')}) STRICT"
        end
      end

      class Editor
        attr_reader :actions
        def initialize(schema); @schema, @actions = schema, []; end

        def add_column(table, column, type: :string)
          table, column = @schema.identifier(table), @schema.identifier(column)
          fields = @schema.table(table)
          raise ConfigurationError, "Column already exists" if fields.key?(column)
          fields[column] = @schema.validate_type(type)
          @actions << "ALTER TABLE #{@schema.quote(table)} ADD COLUMN #{@schema.quote(column)} #{TYPES.fetch(type)}"
        end
      end
    end
  end
end
