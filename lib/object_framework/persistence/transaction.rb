# frozen_string_literal: true

module ObjectFramework
  module Persistence
    class ClosedTransaction < StandardError; end
    class ReadOnlyTransaction < StandardError; end

    # Base lifecycle for read/write storage transactions. Adapters implement
    # row access, commit, and storage cleanup. #close rolls back an active
    # transaction and is safe to repeat. Committed transactions cannot be reused.
    class Transaction
      attr_reader :state, :mode

      def initialize(mode:)
        raise ConfigurationError, "Invalid transaction mode" unless %i[read write].include?(mode)
        @mode, @state, @closed = mode, :active, false
      end

      def rollback
        active!
        rollback_storage
        @state = :rolled_back
      end

      def close
        return if @closed
        begin
          rollback if @state == :active
        ensure
          @closed = true
          close_storage
        end
      end

      private

      def active!
        raise ClosedTransaction, "Transaction is no longer active" if @closed || @state != :active
      end

      def writable!
        active!
        raise ReadOnlyTransaction, "Cannot modify a read transaction" unless mode == :write
      end

      def row_value(row, id: row[:id])
        raise InvalidInput, "A row identity is required" unless id.is_a?(String) && !id.empty?
        raise InvalidInput, "Row identity cannot change" unless row[:id] == id
        row.each_key { |field| Query.identifier(field) }
        Values.detach(row)
      end

      def rollback_storage; end
      def close_storage; end
    end
  end
end
