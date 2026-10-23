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
require_relative "object_framework/http/protocol"
require_relative "object_framework/http/router"
require_relative "object_framework/http/presentation"
require_relative "object_framework/http/io"
require_relative "object_framework/http/server"
require_relative "object_framework/protobuf"
require_relative "object_framework/grpc/service"

module ObjectFramework
  VERSION = "0.1.0"
  autoload :SQLite, File.expand_path("object_framework/sqlite", __dir__)
end
