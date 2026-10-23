# frozen_string_literal: true

module ObjectFramework
  module SQLite
    class Compiler
      OPERATORS = { eq: "=", ne: "!=", gt: ">", gte: ">=", lt: "<", lte: "<=" }.freeze

      def initialize(schema:)
        @schema = schema
      end

      def query(query)
        @schema.table(query.table)
        bindings = []
        sql = "SELECT * FROM #{@schema.quote(query.table)}"
        unless query.criteria.empty?
          sql += " WHERE " + query.criteria.map { |criterion| predicate(query.table, criterion, bindings) }.join(" AND ")
        end
        ordering = query.ordering.any? { |field, _| field == :id } ? query.ordering : query.ordering + [[:id, :asc]]
        sql += " ORDER BY " + ordering.map do |field, direction|
          @schema.type(query.table, field)
          "#{@schema.quote(field)} #{direction == :desc ? 'DESC' : 'ASC'}"
        end.join(", ")
        if query.row_limit || query.row_offset.positive?
          sql += " LIMIT ? OFFSET ?"
          bindings += [query.row_limit || -1, query.row_offset]
        end
        [sql, bindings]
      end

      def encode(table, column, value)
        type = @schema.type(table, column)
        return nil if value.nil?
        valid = case type
        when :string, :blob then value.is_a?(String)
        when :integer then value.is_a?(Integer) && value.between?(-(2**63), 2**63 - 1)
        when :float then value.is_a?(Numeric) && value.to_f.finite?
        when :boolean then value == true || value == false
        end
        raise InvalidInput, "Invalid storage field type" unless valid
        return value ? 1 : 0 if type == :boolean
        return ::SQLite3::Blob.new(value) if type == :blob
        value
      end

      def decode(table, row)
        return nil unless row
        Values.detach(row.to_h do |column, value|
          type = @schema.type(table, column)
          [column.to_sym, type == :boolean && !value.nil? ? value != 0 : value]
        end)
      end

      private

      def predicate(table, criterion, bindings)
        field = @schema.quote(criterion.field)
        @schema.type(table, criterion.field)
        if criterion.operator == :in
          values = criterion.value.reject(&:nil?)
          parts = []
          unless values.empty?
            bindings.concat(values.map { |value| encode(table, criterion.field, value) })
            parts << "#{field} IN (#{(['?'] * values.size).join(', ')})"
          end
          parts << "#{field} IS NULL" if criterion.value.include?(nil)
          return parts.empty? ? "0" : "(#{parts.join(' OR ')})"
        end
        if criterion.value.nil? && %i[eq ne].include?(criterion.operator)
          return "#{field} IS #{criterion.operator == :ne ? 'NOT ' : ''}NULL"
        end
        bindings << encode(table, criterion.field, criterion.value)
        "#{field} #{OPERATORS.fetch(criterion.operator)} ?"
      end
    end
  end
end
