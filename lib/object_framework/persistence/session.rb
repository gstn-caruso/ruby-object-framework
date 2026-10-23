# frozen_string_literal: true

module ObjectFramework
  module Persistence
    class IdentityMap
      def initialize
        @entities = {}
      end

      def find(type, id); @entities[[type, id]]; end

      def add(type, id, entity)
        existing = find(type, id)
        raise Duplicate, "Identity already belongs to another object" if existing && !existing.equal?(entity)
        @entities[[type, Values.detach(id)]] = entity
      end

      def remove(type, id); @entities.delete([type, id]); end
      def clear; @entities.clear; end
    end

    Entry = Struct.new(:entity, :identity, :mapping, :baseline, :state, :loaded, keyword_init: true)

    class UnitOfWork
      def initialize(transaction:)
        @transaction, @entries = transaction, {}.compare_by_identity
      end

      def entry(entity); @entries.fetch(entity); end
      def tracked?(entity); @entries.key?(entity); end

      def track(entity, mapping:, baseline:, state: :clean)
        @entries[entity] ||= Entry.new(entity:, identity: Values.detach(mapping.identity.reader.call(entity)), mapping:, baseline:, state:, loaded: [])
      end

      def remove(entity)
        entry = @entries.fetch(entity) { raise InvalidInput, "Entity is not managed by this session" }
        if entry.state == :new
          @entries.delete(entity)
        else
          entry.state = :deleted
        end
      end

      def flush
        @entries.values.each do |entry|
          entity, mapping = entry.entity, entry.mapping
          id = mapping.identity.reader.call(entity)
          raise InvalidInput, "Managed identity cannot change" unless entry.identity == id
          if entry.state == :deleted
            @transaction.delete(mapping.table, id)
            @entries.delete(entity)
            next
          end
          row = mapping.dump(entity, baseline: entry.baseline, loaded: entry.loaded)
          if entry.state == :new
            @transaction.insert(mapping.table, row)
          elsif row != entry.baseline
            @transaction.update(mapping.table, id, row)
          end
          entry.baseline, entry.state = row, :clean
        end
      end

      def clear; @entries.clear; end
    end

    # Owns an identity map and unit of work for one active transaction.
    # Managed entities stay inside the invocation; return independent values
    # to callers. Application#invoke flushes and closes its session automatically.
    class Session
      attr_reader :transaction

      def initialize(transaction:, mappings:)
        @transaction, @mappings = transaction, mappings
        @identities, @work = IdentityMap.new, UnitOfWork.new(transaction:)
        @closed, @removed = false, {}
      end

      # Tracks a new mapped entity, assigning a UUID when its identity is nil.
      # Returns the entity. Duplicate identities and previously removed
      # entities cannot be registered as new objects in this session.
      def add(entity)
        active!
        mapping = @mappings.fetch(entity.class)
        unless mapping.identity.reader.call(entity)
          mapping.identity.writer.call(entity, SecureRandom.uuid)
        end
        if @removed.key?([entity.class, mapping.identity.reader.call(entity)])
          raise InvalidInput, "Removed entities cannot be registered again"
        end
        @identities.add(entity.class, mapping.identity.reader.call(entity), entity)
        @work.track(entity, mapping:, baseline: nil, state: :new)
        entity
      end

      # Finds a mapped entity by identity or raises NotFound. Repeated lookups
      # return the same object. +load+ explicitly selects associations, with
      # nested hashes for nested loading; no implicit lazy loading occurs.
      def find(type, id, load: [])
        active!
        raise NotFound, "Entity was removed" if @removed.key?([type, id])
        entity = @identities.find(type, id)
        unless entity
          mapping = @mappings.fetch(type)
          row = transaction.find(mapping.table, id)
          raise NotFound, "Entity not found" unless row
          entity = attach(mapping, row)
        end
        load_associations(entity, load)
        entity
      end

      # Returns managed entities matching an immutable Query and optional
      # association loading plan. Removed identities are excluded.
      def query(type, query = Query.new, load: [])
        active!
        mapping = @mappings.fetch(type)
        transaction.query(query.for_table(mapping.table)).reject { |row| @removed.key?([type, row[:id]]) }.map do |row|
          entity = @identities.find(type, row[:id]) || attach(mapping, row)
          load_associations(entity, load)
          entity
        end
      end

      # Schedules deletion of a managed entity, or discards a pending insert.
      def remove(entity)
        active!
        id = @work.entry(entity).identity
        @work.remove(entity)
        @removed[[entity.class, id]] = true
        @identities.remove(entity.class, id)
      end

      # Writes tracked inserts, changes, and deletions without committing.
      # Managed identities cannot change. Requires an active session.
      def flush
        active!
        @work.flush
      end

      def close
        @closed = true
        @identities.clear
        @work.clear
        @removed.clear
      end

      private

      def active!
        raise ClosedSession, "Session is closed" if @closed
        raise ClosedSession, "Session transaction is no longer active" unless transaction.state == :active
      end

      def attach(mapping, row)
        entity = mapping.hydrate(row)
        @identities.add(mapping.entity_class, row[:id], entity)
        @work.track(entity, mapping:, baseline: row)
        entity
      end

      def load_associations(entity, plan)
        entry = @work.entry(entity)
        plan.each do |item|
          name, nested = item.is_a?(Hash) ? item.first : [item, []]
          association = entry.mapping.associations.find { |candidate| candidate.name == name }
          raise ConfigurationError, "Unknown association: #{name}" unless association
          unless entry.loaded.include?(name)
            entry.loaded << name
            value = if association.kind == :belongs_to
              id = entry.baseline&.fetch(association.foreign_key, nil)
              find(association.target, id) if id
            else
              id = entry.mapping.identity.reader.call(entity)
              query(association.target, Query.new.where(**{ association.foreign_key => id }))
            end
            association.writer.call(entity, value)
          end
          value = association.reader.call(entity)
          children = association.kind == :has_many ? value : [value].compact
          children.each { |child| load_associations(child, nested) } unless nested.empty?
        end
      end
    end
  end
end
