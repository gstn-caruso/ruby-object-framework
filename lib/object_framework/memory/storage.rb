# frozen_string_literal: true

module ObjectFramework
  # Volatile, process-local persistence using revision-checked snapshots.
  module Memory
    # Thread-safe storage adapter. Writes publish their complete snapshot
    # atomically; a competing commit raises Conflict without automatic retry.
    # Data is lost when the storage is closed or the process exits.
    class Storage
      def initialize
        @mutex, @tables, @revision, @closed = Mutex.new, {}, 0, false
      end

      # Opens an independent snapshot in +:read+ or +:write+ mode.
      # The caller must close the transaction; Application#invoke owns this
      # lifecycle when the adapter is installed in an application.
      def begin_transaction(mode:)
        @mutex.synchronize do
          raise Unavailable, "Storage is closed" if @closed
          Transaction.new(storage: self, tables: @tables.transform_values(&:dup), revision: @revision, mode:)
        end
      end

      def publish(tables, revision:)
        @mutex.synchronize do
          raise Unavailable, "Storage is closed" if @closed
          raise Conflict, "Snapshot revision changed" unless revision == @revision
          # Publishing the whole table set under one lock makes multi-row commits atomic.
          @tables = tables.transform_values { |rows| rows.dup.freeze }.freeze
          @revision += 1
        end
      end

      def close
        @mutex.synchronize { @closed = true; @tables = {} }
      end
    end

    class Transaction < Persistence::Transaction
      def initialize(storage:, tables:, revision:, mode:)
        super(mode:)
        @storage, @tables, @revision, @dirty = storage, tables, revision, false
      end

      def find(table, id)
        active!
        row = rows(table)[id]
        Values.detach(row) if row
      end

      def query(query)
        active!
        Values.detach(query.apply(rows(query.table).values))
      end

      def insert(table, row)
        writable!
        value = row_value(row)
        raise Duplicate, "Duplicate identity" if rows(table).key?(value[:id])
        rows(table)[value[:id]] = value
        @dirty = true
        value[:id]
      end

      def update(table, id, row)
        writable!
        raise NotFound, "Unknown identity" unless rows(table).key?(id)
        rows(table)[id] = row_value(row, id:)
        @dirty = true
      end

      def delete(table, id)
        writable!
        raise NotFound, "Unknown identity" unless rows(table).key?(id)
        rows(table).delete(id)
        @dirty = true
      end

      def commit
        active!
        @storage.publish(@tables, revision: @revision) if @dirty
        @state = :committed
      rescue Conflict
        @state = :rolled_back
        @tables.clear
        raise
      end

      private

      def rows(table)
        @tables[Persistence::Query.identifier(table)] ||= {}
      end

      def rollback_storage
        @tables.clear
      end

      def close_storage
        @tables.clear
      end
    end
  end
end
