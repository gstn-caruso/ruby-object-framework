# frozen_string_literal: true

module ObjectFramework
  module Persistence
    Criterion = Data.define(:field, :operator, :value)

    class Query
      OPERATORS = %i[eq ne gt gte lt lte in].freeze
      attr_reader :table, :criteria, :ordering, :row_limit, :row_offset

      def self.identifier(name)
        raise ConfigurationError, "Invalid storage identifier: #{name.inspect}" unless /\A[a-zA-Z_][a-zA-Z0-9_]*\z/.match?(name.to_s)
        name.to_sym
      end

      def initialize(table: nil, criteria: [], ordering: [], row_limit: nil, row_offset: 0)
        @table = self.class.identifier(table) if table
        @criteria, @ordering = criteria.freeze, ordering.freeze
        @row_limit, @row_offset = row_limit, row_offset
        freeze
      end

      def for_table(table)
        copy(table:)
      end

      def where(**attributes)
        attributes.reduce(self) { |query, (field, value)| query.compare(field, :eq, value) }
      end

      def compare(field, operator, value)
        raise ConfigurationError, "Unsupported query operator" unless OPERATORS.include?(operator)
        raise ConfigurationError, "IN requires an array" if operator == :in && !value.is_a?(Array)
        criterion = Criterion.new(field: self.class.identifier(field), operator:, value: Values.detach(value))
        copy(criteria: criteria + [criterion])
      end

      def order(field, direction = :asc)
        raise ConfigurationError, "Invalid ordering direction" unless %i[asc desc].include?(direction)
        copy(ordering: ordering + [[self.class.identifier(field), direction].freeze])
      end

      def limit(count)
        copy(row_limit: nonnegative(count))
      end

      def offset(count)
        copy(row_offset: nonnegative(count))
      end

      def apply(rows)
        selected = rows.select { |row| criteria.all? { |criterion| matches?(row, criterion) } }
        ordering = @ordering.any? { |field, _| field == :id } ? @ordering : @ordering + [[:id, :asc]]
        selected.sort! do |left, right|
          ordering.each do |field, direction|
            a, b = left[field], right[field]
            comparison = if a.nil? then b.nil? ? 0 : -1 elsif b.nil? then 1 else a <=> b end
            raise InvalidInput, "Incomparable query values" unless comparison
            break(direction == :desc ? -comparison : comparison) unless comparison.zero?
          end.then { |result| result.is_a?(Integer) ? result : 0 }
        end
        selected = selected.drop(row_offset)
        row_limit ? selected.take(row_limit) : selected
      end

      private

      def copy(**changes)
        self.class.new(**{ table:, criteria:, ordering:, row_limit:, row_offset: }.merge(changes))
      end

      def nonnegative(count)
        raise ConfigurationError, "Expected a nonnegative integer" unless count.is_a?(Integer) && count >= 0
        count
      end

      def matches?(row, criterion)
        actual, expected = row[criterion.field], criterion.value
        case criterion.operator
        when :eq then actual == expected
        when :ne then !actual.nil? && actual != expected
        when :in then criterion.value.include?(actual)
        else
          return false if actual.nil? || expected.nil?
          comparison = actual <=> expected
          return false unless comparison
          case criterion.operator
          when :gt then comparison > 0
          when :gte then comparison >= 0
          when :lt then comparison < 0
          when :lte then comparison <= 0
          end
        end
      end
    end
  end
end
