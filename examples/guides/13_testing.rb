# frozen_string_literal: true

require_relative "../../test/support/spec"

class PriceWithTax
  def call(cents:)
    raise ArgumentError, "Price must be nonnegative" if cents.negative?
    cents + cents / 5
  end
end

Spec.test "a zero price remains zero" do
  assert_equal 0, PriceWithTax.new.call(cents: 0)
end

Spec.test "a price includes twenty percent tax" do
  assert_equal 1200, PriceWithTax.new.call(cents: 1000)
end

Spec.test "negative prices are rejected" do
  assert_raises(ArgumentError) { PriceWithTax.new.call(cents: -1) }
end

exit Spec.run
