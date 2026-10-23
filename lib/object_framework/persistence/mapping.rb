# frozen_string_literal: true

module ObjectFramework
  # External domain mappings, immutable queries, and invocation-owned sessions.
  module Persistence
    # Converts a field between domain values and independent storage values.
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

    # Explicit association declarations used by Mapping.
    module AssociationDSL
      ##
      # :method: belongs_to
      # :args: name, target:, foreign_key:, read: nil, write: nil
      #
      # Declares a reference to +target+, storing its UUID in +foreign_key+ on
      # this mapping's table. The target must have a registered Mapping.
      # Optional +read+ and +write+ callables replace public attribute accessors.
      # Returns +self+. Associations load only when requested through a
      # Session#find or Session#query load plan.
      #
      #   belongs_to :customer, target: Customer, foreign_key: :customer_id

      ##
      # :method: has_many
      # :args: name, target:, foreign_key:, read: nil, write: nil
      #
      # Declares a collection of +target+ entities whose +foreign_key+ refers
      # to this entity's UUID. The target mapping must expose that foreign key
      # as a field or a belongs-to association. Optional +read+ and +write+
      # callables replace public attribute accessors. Returns +self+.
      # Collections load only through an explicit session load plan.
      #
      #   has_many :purchases, target: Purchase, foreign_key: :customer_id

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

    # Describes how an ordinary Ruby class is hydrated and stored.
    # An +id+ field mapped to the +id+ column is required. Declarations become
    # immutable when their Mappings collection is validated at startup.
    class Mapping
      include AssociationDSL
      TYPES = %i[string integer float boolean blob].freeze
      attr_reader :entity_class, :table, :fields, :associations

      def initialize(entity_class, table:)
        @entity_class, @table = entity_class, Query.identifier(table)
        @fields, @associations = [], []
        @builder = ->(attributes) { entity_class.new(**attributes) }
      end

      # Maps an attribute to a column using a type in TYPES. Optional +read+
      # and +write+ callables replace public attribute accessors. +converter+
      # supplies +dump+ and +load+ transformations. Returns +self+.
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

      # Replaces keyword construction with a callable receiving an attributes
      # hash. Use this when hydration needs a domain-specific constructor.
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

    # Owns the application's mappings without modifying domain classes.
    #
    #   mappings = ObjectFramework::Persistence::Mappings.new
    #   mappings.define(Order, table: :orders) do
    #     field :id
    #     field :status
    #   end
    class Mappings
      include Enumerable

      def initialize
        @mappings = {}
      end

      # Registers one Mapping per domain class and table. Evaluates the
      # declaration block against that mapping and returns it.
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
