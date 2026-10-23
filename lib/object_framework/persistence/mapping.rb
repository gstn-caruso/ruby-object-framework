# frozen_string_literal: true

module ObjectFramework
  module Persistence
    class Converter
      def initialize(dump: ->(value) { value }, load: ->(value) { value })
        @dump, @load = dump, load
        freeze
      end

      def dump(value); @dump.call(value); end
      def load(value); @load.call(value); end
    end

    Field = Data.define(:name, :column, :type, :converter, :reader, :writer)
    Association = Data.define(:name, :kind, :target, :foreign_key, :reader, :writer)

    module AssociationDSL
      %i[belongs_to has_many].each do |kind|
        define_method(kind) do |name, target:, foreign_key:, read: nil, write: nil|
          mutable!
          name = Query.identifier(name)
          raise ConfigurationError, "Duplicate mapped attribute" if (@fields + @associations).any? { |item| item.name == name }
          foreign_key = Query.identifier(foreign_key)
          if kind == :belongs_to && columns.include?(foreign_key)
            raise ConfigurationError, "Duplicate storage column"
          end
          @associations << Association.new(name:, kind:, target:, foreign_key:,
            reader: read || ->(entity) { entity.public_send(name) },
            writer: write || ->(entity, value) { entity.public_send("#{name}=", value) })
          self
        end
      end
    end

    class Mapping
      include AssociationDSL
      TYPES = %i[string integer float boolean blob].freeze
      attr_reader :entity_class, :table, :fields, :associations

      def initialize(entity_class, table:)
        @entity_class, @table = entity_class, Query.identifier(table)
        @fields, @associations = [], []
        @builder = ->(attributes) { entity_class.new(**attributes) }
      end

      def field(name, column: name, type: :string, converter: Converter.new, read: nil, write: nil)
        mutable!
        name, column = Query.identifier(name), Query.identifier(column)
        raise ConfigurationError, "Unsupported column type" unless TYPES.include?(type)
        raise ConfigurationError, "Duplicate mapped column or attribute" if columns.include?(column) || (@fields + @associations).any? { |item| item.name == name }
        @fields << Field.new(name:, column:, type:, converter:,
          reader: read || ->(entity) { entity.public_send(name) },
          writer: write || ->(entity, value) { entity.public_send("#{name}=", value) })
        self
      end

      def build(&builder)
        mutable!
        @builder = builder
        self
      end

      def identity
        fields.find { |field| field.name == :id } || raise(ConfigurationError, "Mapping requires an id field")
      end

      def columns
        fields.map(&:column) + associations.select { |item| item.kind == :belongs_to }.map(&:foreign_key)
      end

      def schema
        fields.to_h { |field| [field.column, field.type] }.merge(
          associations.select { |item| item.kind == :belongs_to }.to_h { |item| [item.foreign_key, :string] }
        ).freeze
      end

      def hydrate(row)
        @builder.call(fields.to_h { |field| [field.name, field.converter.load(Values.mutable_copy(row[field.column]))] })
      end

      def dump(entity, baseline: nil, loaded: [])
        row = fields.to_h { |field| [field.column, field.converter.dump(field.reader.call(entity))] }
        associations.select { |association| association.kind == :belongs_to }.each do |association|
          target = association.reader.call(entity)
          row[association.foreign_key] = if target
            target.public_send(:id) || raise(InvalidInput, "Associated entities must be registered before flush")
          elsif baseline && !loaded.include?(association.name)
            baseline[association.foreign_key]
          end
        end
        Values.detach(baseline ? baseline.merge(row) : row)
      end

      def finalize!
        identity
        raise ConfigurationError, "Identity must map to the id column" unless identity.column == :id
        fields.freeze
        associations.freeze
        freeze
      end

      private

      def mutable!
        raise ConfigurationError, "Mapping is finalized" if frozen?
      end
    end

    class Mappings
      include Enumerable

      def initialize
        @mappings = {}
      end

      def define(entity_class, table:, &description)
        raise ConfigurationError, "Mappings are finalized" if @mappings.frozen?
        raise ConfigurationError, "Duplicate entity mapping" if @mappings.key?(entity_class)
        raise ConfigurationError, "Duplicate table mapping" if @mappings.values.any? { |mapping| mapping.table == table.to_sym }
        mapping = Mapping.new(entity_class, table:)
        mapping.instance_eval(&description) if description
        @mappings[entity_class] = mapping
      end

      def each(&block)
        @mappings.values.each(&block)
      end

      def fetch(entity_class)
        @mappings.fetch(entity_class) { raise ConfigurationError, "Unmapped entity: #{entity_class}" }
      end

      def validate!
        each do |mapping|
          mapping.identity
          mapping.associations.each do |association|
            target = fetch(association.target)
            if association.kind == :has_many && !target.columns.include?(association.foreign_key)
              raise ConfigurationError, "Collection foreign key is not mapped"
            end
          end
        end
        each(&:finalize!)
        @mappings.freeze
        self
      end
    end
  end
end
