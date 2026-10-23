# frozen_string_literal: true

module ObjectFramework
  module SQLite
    module ErrorTranslation
      def self.raise_translated(error)
        code = error.code
        type = case code
        when 1555, 2067 then Duplicate
        when 517 then Conflict
        when 787, 1299, 275, 3091 then InvalidInput
        else
          case code & 255
          when 5, 6, 10, 13, 14 then Unavailable
          when 19, 20, 18 then InvalidInput
          else nil
          end
        end
        raise(type.new("SQLite operation failed"), cause: error) if type
        raise error
      end
    end

    class Storage
      attr_reader :schema_version

      def initialize(path:, schema:, lock_timeout: 1)
        raise ConfigurationError, "SQLite requires a database file path" if path.to_s.empty? || path.to_s == ":memory:"
        raise ConfigurationError, "Lock timeout must be positive" unless lock_timeout.is_a?(Numeric) && lock_timeout.positive?
        @path, @schema, @lock_timeout = File.expand_path(path), schema.finalize!, lock_timeout
        @mutex, @connections, @closed = Mutex.new, 0, false
        migrate
      end

      def open_connection_count; @mutex.synchronize { @connections }; end

      def begin_transaction(mode:)
        begin_transaction_for(mode:, context: ExecutionContext.new)
      end

      def begin_transaction_for(mode:, context:)
        @mutex.synchronize { raise Unavailable, "Storage is closed" if @closed }
        context.cancellation.check!
        database = connect(cancellation: context.cancellation)
        Transaction.new(database:, schema: @schema, mode:, cancellation: context.cancellation,
          closed: -> { disconnected })
      rescue Exception
        if database && !database.closed?
          database.close
          disconnected
        end
        raise
      end

      def close
        @mutex.synchronize { @closed = true }
      end

      private

      def connect(cancellation: Cancellation.new)
        database = ::SQLite3::Database.new(@path, results_as_hash: true)
        @mutex.synchronize { @connections += 1 }
        database.extended_result_codes = true
        lock_started = nil
        database.busy_handler do |count|
          cancellation.check!
          lock_started = monotonic if count.zero? || lock_started.nil?
          remaining = @lock_timeout - (monotonic - lock_started)
          if remaining.positive?
            sleep [remaining, 0.005].min
            true
          else
            false
          end
        end
        database.execute("PRAGMA foreign_keys = ON")
        database.execute("PRAGMA synchronous = FULL")
        database
      rescue Exception => error
        if database
          database.close unless database.closed?
          disconnected
        end
        ErrorTranslation.raise_translated(error) if error.is_a?(::SQLite3::Exception)
        raise
      end

      def disconnected
        @mutex.synchronize { @connections -= 1 }
      end

      def migrate
        database = connect
        database.execute("PRAGMA journal_mode = DELETE")
        database.execute("BEGIN IMMEDIATE")
        current = database.get_first_value("PRAGMA user_version")
        raise ConfigurationError, "Database schema is newer than the application" if current > @schema.version
        @schema.migrations.each do |migration|
          next if migration.version <= current
          statements = migration.version == 1 ? @schema.create_statements : migration.actions
          statements.each { |statement| database.execute(statement) }
          database.execute("PRAGMA user_version = #{migration.version}")
        end
        validate_schema(database)
        database.execute("COMMIT")
        @schema_version = @schema.version
      rescue ::SQLite3::Exception => error
        ErrorTranslation.raise_translated(error)
      ensure
        if database
          database.close
          disconnected
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def validate_schema(database)
        @schema.tables.each do |name, columns|
          actual = database.execute("PRAGMA table_info(#{@schema.quote(name)})").to_h { |row| [row.fetch("name"), row.fetch("type")] }
          expected = columns.to_h { |column, type| [column.to_s, Schema::TYPES.fetch(type)] }
          raise ConfigurationError, "SQLite schema does not match its declared version" unless actual == expected
        end
      end
    end

    class Transaction < Persistence::Transaction
      def initialize(database:, schema:, mode:, cancellation:, closed:)
        super(mode:)
        @database, @schema, @cancellation, @closed_callback = database, schema, cancellation, closed
        @compiler = Compiler.new(schema:)
        execute(mode == :write ? "BEGIN IMMEDIATE" : "BEGIN DEFERRED")
        @database.execute("PRAGMA query_only = ON") if mode == :read
      end

      def configuration
        active!
        %i[foreign_keys journal_mode synchronous].to_h { |name| [name, @database.get_first_value("PRAGMA #{name}")] }
      end

      def find(table, id)
        query(Persistence::Query.new(table:).where(id:).limit(1)).first
      end

      def query(query)
        active!
        sql, bindings = @compiler.query(query)
        execute(sql, bindings).map { |row| @compiler.decode(query.table, row) }
      end

      def insert(table, row)
        writable!
        value = row_value(row)
        @schema.table(table)
        columns = value.keys
        bindings = columns.map { |column| @compiler.encode(table, column, value[column]) }
        execute("INSERT INTO #{@schema.quote(table)} (#{columns.map { |column| @schema.quote(column) }.join(', ')}) VALUES (#{(['?'] * columns.size).join(', ')})", bindings)
        value[:id]
      end

      def update(table, id, row)
        writable!
        value = row_value(row, id:)
        @schema.table(table)
        columns = @schema.table(table).keys - [:id]
        if columns.empty?
          raise NotFound, "Unknown identity" unless find(table, id)
          return
        end
        values = columns.map { |column| @compiler.encode(table, column, value[column]) }
        sql = "UPDATE #{@schema.quote(table)} SET #{columns.map { |column| "#{@schema.quote(column)} = ?" }.join(', ')} WHERE \"id\" = ?"
        execute(sql, values + [id])
        raise NotFound, "Unknown identity" if @database.changes.zero?
      end

      def delete(table, id)
        writable!
        @schema.table(table)
        execute("DELETE FROM #{@schema.quote(table)} WHERE \"id\" = ?", [id])
        raise NotFound, "Unknown identity" if @database.changes.zero?
      end

      def commit
        active!
        begin
          execute("COMMIT")
          @state = :committed
        rescue StandardError
          @state = :indeterminate unless @database.transaction_active?
          raise
        end
      end

      private

      def execute(sql, bindings = [])
        @cancellation.check!
        @database.execute(sql, bindings)
      rescue ::SQLite3::Exception => error
        ErrorTranslation.raise_translated(error)
      end

      def rollback_storage
        # Cleanup must remain possible after deadline expiry or cancellation.
        @database.execute("ROLLBACK")
      rescue ::SQLite3::Exception => error
        ErrorTranslation.raise_translated(error)
      end

      def close_storage
        @database.close
      ensure
        @closed_callback.call
      end
    end
  end
end
