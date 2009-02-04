require 'couchrest'

# This class wrappers CouchRest but may ultimately replace it as only parts of the library are used
module CouchFoo  
  LATEST_COUCHDB_VERSION = 0.9
  
  class DatabaseWrapper
    
    attr_accessor :database, :database_version, :bulk_save_default
    
    def initialize(database_url, bulk_save_default, version, *args)
      self.database = CouchRest.database(database_url)
      self.bulk_save_default = bulk_save_default
      self.database_version = version
    end
    
    def save(doc, bulk_save = bulk_save?)
      begin
        response = database.save(doc, bulk_save)
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
      elsif exception.is_a?(RestClient::RequestFailed) && exception.code == "409"
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
            raise Exception, "No databases setup"
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
      # For ultra-scalability and using a different database for each user, perform the set_database
      # call on the CouchFoo::Base object on a before_filter using the session information to
      # determine the database to connect to.  For example:
      #
      # class ApplicationController < ActionController::Base
      #   before_filter :set_user_database
      #
      #   def set_user_database
      #     CouchFoo::Base.set_database("http://localhost:5984/user#{session[:user]}")
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
      def set_database(url, version = LATEST_COUCHDB_VERSION, bulk_save = bulk_save_default)
        @active_database = DatabaseWrapper.new(url, bulk_save, version)
      end
    end # ClassMethods
  end
end