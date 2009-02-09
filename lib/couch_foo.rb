require 'rubygems'
require 'active_support'
require 'json'
require 'json/add/core'
require 'json/add/rails'
require 'uuid'
require 'ostruct'

require 'boolean'
require 'couch_foo/base'
require 'couch_foo/database'
require 'couch_foo/view_methods'
require 'couch_foo/named_scope'
require 'couch_foo/observer'
#require 'active_record/query_cache'
require 'couch_foo/validations'
require 'couch_foo/callbacks'
require 'couch_foo/reflection'
require 'couch_foo/associations'
#require 'active_record/association_preload'
#require 'active_record/aggregations'
require 'couch_foo/timestamp'
require 'couch_foo/calculations'
require 'couch_foo/serialization'
require 'couch_foo/attribute_methods'
require 'couch_foo/dirty'

CouchFoo::Base.class_eval do
#  extend ActiveRecord::QueryCache
  include CouchFoo::Validations
  include CouchFoo::AttributeMethods
  include CouchFoo::Database
  include CouchFoo::ViewMethods
  include CouchFoo::Dirty
  include CouchFoo::Callbacks
  include CouchFoo::Observing
  include CouchFoo::Timestamp
  include CouchFoo::Associations
  include CouchFoo::NamedScope
#  include ActiveRecord::AssociationPreload
#  include ActiveRecord::Aggregations
  include CouchFoo::Reflection
  include CouchFoo::Calculations
  include CouchFoo::Serialization
end
