# frozen_string_literal: true

require "securerandom"
require "thread"
require_relative "object_framework/errors"
require_relative "object_framework/execution"
require_relative "object_framework/application"
require_relative "object_framework/persistence/query"
require_relative "object_framework/persistence/transaction"
require_relative "object_framework/persistence/mapping"
require_relative "object_framework/persistence/session"
require_relative "object_framework/memory/storage"

module ObjectFramework
  VERSION = "0.1.0"
end
