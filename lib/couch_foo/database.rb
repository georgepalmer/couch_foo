require 'couchrest'
require 'couch_foo/database_version.rb'

# This class wrappers CouchRest but may ultimately replace it as only parts of the library are used
module CouchFoo 
  class DatabaseWrapper
    
    attr_accessor :database, :database_version, :bulk_save_default
    
    def initialize(options, bulk_save_default, *args)
      self.database = CouchRest.database(options[:host] + "/" + options[:database])
      self.bulk_save_default = bulk_save_default
      
      # Check database ok
      begin
        self.database_version = DatabaseVersion.new((JSON.parse(RestClient.get(options[:host]))["version"]).gsub(/-.+/,""))
      rescue Exception => e
        if e.is_a?(Errno::ECONNREFUSED)
          raise CouchFooError, "CouchDB not started"
        else
          raise CouchFooError, "Error determining CouchDB version"
        end
      end
      
      # Due to CouchDB view API changes in 0.9 and CouchREST only supporting newer version
      if version > 0.8 && CouchRest::VERSION.to_f < 0.21
        raise CouchFooError, "CouchFoo requires CouchRest > 0.2 for use with CouchDB 0.9"
      elsif version < 0.9 && (CouchRest::VERSION.to_f >= 0.21 || CouchRest::VERSION.to_f <= 0.15)
        raise CouchFooError, "CouchFoo requires 0.15 < CouchRest < 0.21 for use with CouchDB 0.8"
      end
    end
    
    def save(doc, bulk_save = bulk_save?)
      begin
        response = database.save_doc(doc, bulk_save)
        check_response_ok(response)
      rescue Exception => e
        handle_exception(e)
      end
    end
    
    def delete(doc)
      begin
        response = database.delete(doc)
        check_response_ok(response)
      rescue Exception => e
        handle_exception(e)
      end
    end
    
    def commit
      begin
        response = database.bulk_save
        check_response_ok(response)
      rescue Exception => e
        handle_exception(e)
      end
    end

    def get(doc)
      begin
        database.get(doc)
      rescue Exception => e
        handle_exception(e)
      end
    end
    
    def view(doc, params)
      begin
        database.view(doc, params)
      rescue Exception => e
        handle_exception(e)
      end
    end
    
    def slow_view(doc, params)
      begin
        database.slow_view(doc, params)
      rescue Exception => e
        handle_exception(e)
      end
    end
    
    # At the moment this is limited by the CouchREST bulk save limit of 50 transactions
    def transaction(&block)
      yield
      commit
    end
    
    def bulk_save?
      bulk_save_default
    end
    
    def version
      database_version
    end
    
    private
    # Checks the response is ok, raises generic exception if not
    def check_response_ok(response)
      if response["ok"]
        response
      else
        logger.error("Unexpected response from database - #{response['ok']}")
        raise CouchFooError, "Couldn't understand database response:#{response}"
      end
    end
    
    # Raises appropriate exceptions based on error from server
    def handle_exception(exception)
      if exception.is_a?(RestClient::ResourceNotFound)
        raise DocumentNotFound, "Couldn't find document"
      elsif exception.is_a?(RestClient::RequestFailed) && exception.respond_to?(:http_code) && (exception.http_code == 412 || exception.http_code == 409)
        
        raise DocumentConflict, "Document has been updated whilst object loaded"
      else
        # We let the rest fall through as normally CouchDB setup error
        raise exception
      end
    end
  end
  
  module Database
    def self.included(base)
      base.extend ClassMethods
      base.cattr_accessor :bulk_save_default, :instance_writer => false
      base.class_eval "@@bulk_save_default = false"
    end
    
    module ClassMethods
      # Get the current database
      def database
        if @active_database.nil?
          if self == CouchFoo::Base
            raise CouchFooError, "No databases setup"
          else
            superclass.database
          end
        else
          @active_database
        end
      end

      # Set the database to be used with this model.  This honours inheritence so sub-classes can use
      # different databases from their parents.  As such if you only use one database for your
      # application then only one call is required to CouchFoo::Base for initial setup.
      #
      # When using a database for the first time a version check is performed on CouchDB so that
      # performance optimisations are run according to your database version.  At time of writing
      # CouchDB 0.9 offers some good performance gains over 0.8
      #
      # For ultra-scalability and using a different database for each user, perform the set_database
      # call on the CouchFoo::Base object on a before_filter using the session information to
      # determine the database to connect to.  For example:
      #
      # class ApplicationController < ActionController::Base
      #   before_filter :set_user_database
      #
      #   def set_user_database
      #     CouchFoo::Base.set_database(:host => "http://localhost:5984", :database => "user#{session[:user]}")
      #   end
      # end
      #
      # As the need grows to move user databases onto different servers (sharding) then you can
      # either:<ul>
      # <li>create a lookup file/database that maps user_id to database location</li>
      # <li>locate the database servers behind apache (or equivalent) using rewrite rules.  The server
      #     knows which users live on which physical machine and rewrites accordingly.  Thus only one 
      #     database url is required at the application level)</li>
      # </ul>
      #
      # NOTE: This will work best on domains where there is little overlap between users data (eg basecamp)
      def set_database(options, bulk_save = bulk_save_default)
        @active_database = DatabaseWrapper.new(options, bulk_save)
      end
    end # ClassMethods
  end
end
