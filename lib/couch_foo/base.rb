require 'digest/md5'
require 'couchrest'

module CouchFoo
  
  # Generic Active Record exception class.
  class CouchFooError < StandardError
  end
  
  # Raised when the inheritance mechanism failes to locate the subclass
  # (for example due to improper usage of column that +inheritance_column+ points to).
  class SubclassNotFound < CouchFooError #:nodoc:
  end
  
  # Raised when attribute has a name reserved by CouchFoo
  class DangerousAttributeError < CouchFooError
  end

  # Raised when Couch Foo cannot find the document by given id or set of ids.
  class DocumentNotFound < CouchFooError
  end

  # Raised by save! when record cannot be saved because record is invalid
  class DocumentNotSaved < CouchFooError
  end
  
  # Raised on attempt to update record that is instantiated as read only.
  class ReadOnlyRecord < CouchFooError
  end

  # Raised when attempting to update an old revision of a document
  class DocumentConflict < CouchFooError
  end
  
  # The types that are permitted for properties.  At the moment this is just used
  # to determine whether a .to_xml call should be made on the type during
  # serialization but I imagine it will be used to enforce type checking as well
  # at a later date
  AVAILABLE_TYPES = [String, Integer, Float, DateTime, Time, Date, TrueClass, Boolean]

  # Simple class encapsulating a property
  class Property
    attr_accessor :name, :type, :default
    def initialize(name, type, default = nil, *args)
      self.name = name
      self.type = type
      self.default = default
    end
  end
  
  # Simple class encapsulating a view
  class View
    attr_accessor :name, :map_function, :reduce_function, :options
    def initialize(name, map_function, reduce_function, options, *args)
      self.name = name
      self.map_function = map_function
      self.reduce_function = reduce_function
      self.options = options
    end
  end
  
  # == Introduction
  #
  # CouchDB (http://couchdb.apache.org/) works slightly differently to relational databases.  First, 
  # and foremost, it is a document-orientated database.  That is, data is stored in documents each 
  # of which have a unique id that is used to access and modify it.  The contents of the documents 
  # are free from structure (or schema free) and bare no relation to one another (unless you encode 
  # that within the documents themselves).  So in many ways documents are like records within a 
  # relational database except there are no tables to keep documents of the same type in.
  #
  # CouchDB interfaces with the external world via a RESTful interface.  This allows document
  # creation, updating, deletion etc.  The contents of a document are specified in JSON so its
  # possible to serialise objects within the database record efficiently as well as store all the
  # normal types natively.
  #
  # As a consequence of its free form structure there is no SQL to query the database.  Instead you
  # define (table-oriented) views that emit certain bits of data from the record and apply 
  # conditions, sorting etc to those views.  For example if you were to emit the colour attribute 
  # you could find all documents with a certain colour.  This is similar to indexed lookups on a 
  # relational table (both in terms of concept and performance).
  #
  # CouchDB has been designed from the ground up to operate in a distributed way.  It provides 
  # robust, incremental replication with bi-directional conflict detection and resolution.  It's an
  # excellent choice for unstructed data, large datasets that need sharding efficiently and situations
  # where you wish to run local copies of the database (for example in satellite offices). 
  # 
  # If using CouchDB in a more traditional database sense, it is common to specify a class attribute
  # in the document so that a view can be defined to find all documents of that class.  This is 
  # similar to a relational database table.  CouchFoo defines a ruby_class property that holds the 
  # class name of the model that it's representing.  It is then possible to do User.all for example.   
  # As such it has been possible, with a few minor exceptions, to take the interface to ActiveRecord 
  # and re-implement it for CouchDB.  This should allow for easy migration from MySQL and friends
  # to CouchDB.  Further, CouchFoo, has been designed to take advantages of some features that
  # CouchDB offers that are not available in relational databases.  For example - multiple updates
  # and efficient sharding of data
  #
  # In terms of performance CouchDB operates differently in some areas when compared to relationsal
  # databases.  That's not to say it's better or worse, just different - you pay the price for
  # certain operations at different points.  As such there's a performance section below that
  # details which areas are better performing and which worse.  This is something to be aware when
  # writing or migrating applications and using CouchDB.
  #
  # == Quick start guide - what's different?
  #
  # This section outlines differences between ActiveRecord and CouchFoo and a few specific CouchDB
  # points to be aware of
  # 
  # As CouchDB is schema-free there are no migrations and no schemas to worry about.  You simply
  # specify properties inside the model (a bit like in DataMapper) and add/subtract from them as
  # you need.  Adding new properties initializes that attribute to nil when using a document that 
  # doesn't have the corresponding data and removing a field makes that attribute no longer available 
  # (and removes it from the record on next save).  You can optionally specify a type with a 
  # property although it makes sense to do so if you can (it'll convert to that type).  For example:
  #  
  #   class Address < CouchFoo::Base
  #     property :number, Integer
  #     property :street, String
  #     property :postcode # Any generic type is fine as long as .to_json and class.from_json(json) can be called on it
  #   end
  #
  # Documents have three more properties that get added automatically.  _id and _rev are CouchDB
  # internal properties.  The _id is the document UUID and never changes.  This is created by the
  # gem to be unique accross mulitple computers so should never result in a conflict.  It is also
  # aliased to id to ensure compatability with ActiveRecord.  The _rev attribute is changed by 
  # CouchDB each time an update is made.  It is used internally by CouchDB to detect conflicts.  The
  # final property is ruby_class that is used by CouchFoo to determine which documents map to which
  # models. 
  # 
  # CouchDB has a concept called bulk saving where mutliple operations can be built up and commited
  # at once.  This has the added advantage of being in a transaction so all or none of the operations
  # will complete.  By default bulk saving is switched off but you can set the 
  # CouchFoo::Base.bulk_save_default setting to true to achieve good performance gains when updating
  # large amounts of documents.  Beware it is the developers responsability to commit the work though.
  # For example:
  # 
  #   User.all.size # => 27
  #   User.create(:name => "george")
  #   User.all.size # => 27
  #   User.database.commit # or you can use self.class.database.commit if just using 1 database
  #   User.all.size # => 28
  #
  # If using this option in rails it would be a good idea to specify an after_filter so that any
  # changes are commited at the end of an action.  If you are sharding database across several
  # databases you will need to deal with this in the after_filter logic as well.
  #
  # Conflicts occur when a copy of the document is altered under CouchFoo.  That is since loading
  # the document into memory another person or program has altered its contents.  CouchDB detects
  # this through the _rev attribute.  If a conflict occurs a DocumentConflict error is raised. This
  # is effectively the same as ActiveRecord Optimistic locking mechanism.  Exceptions should be
  # dealt with in application logic if using save! - save will just return false
  #
  # On the finders and associations there are a few options that are no longer relevant - :select,
  # :joins, :having, :group, :from and :lock  Everything else is available although :conditions and
  # :order work slightly differently and :include hasn't been implemented yet.  :conditions is now 
  # only a hash, eg  :conditions => {:user_name => user_name} and doesn't accept an array or SQL.
  # :offset or :skip is quite inefficient so should be used sparingly :order isn't a SQL fragement 
  # but a field to sort the results on - eg :order => :created_at  At the moment this can only be
  # one field so it's best to sort the results yourself once you've got them back if you require
  # complex ordering.  As the order is applied once the results are retrieved from the database it 
  # cannot be used with :limit.  The reason :order is applied after the results are retrieved is 
  # CouchDB can only order on items exposed in the key.  Thus if you wanted to sort User.all 5 
  # different ways throughout your application you would need 5 indexes rather than one.  This is 
  # quite inefficient so ordering is performed once the data is retrieved from the database with 
  # the cost that using :order with :limit has to be performed an alternate way.
  #
  # When using finders views are automatically built by CouchFoo for the model.  For example, with
  # the class House, the first House.find(:id) will create a House design document with a view 
  # that exposes the id of the house as the key - any house can then be selected on this.  If you 
  # then do a query for a certain colour house, ie House.find_all_by_colour("red") then a view that 
  # exposes the house colour as the key will be added to the design document.  This works well when 
  # using conditions (as we can generate the key from the conditions used) but means it's not 
  # possible to find the oldest 5 users in the system if :created_at isn't exposed in the key.  As 
  # such it is possible to set the key to use with a view directly.  For example:
  #
  #   Person.find(:all, :use_key => [:name, :category], :conditions => {:category => "Article"}, :limit => 50) # Finds 50 people with a category of "Article" sorted by name
  #
  # We must use the condition keys in the :use_key array as we want to restrict the results on this.  
  # It should be noted that the query will get the desired results but at the expense of creating a
  # new index so shouldn't be used excessively.  For more complex queries it is also possible to 
  # specify your own map and reduce functions using the CouchFoo#view call.  See the CouchDB view
  # documentation and the CouchFoo#view documentation for more on this.
  #
  # Using relational databases with incrementing keys we have become accustom to adding a new record
  # and then using find(:last) to retrieve it.  As each document in CouchDB has a unique identifier 
  # this may no longer the case.  This is particularly important when creating user interfaces as it 
  # is normal to add items to the bottom of lists and expect on reload for the order to be maintained.
  # In couch_foo items are sorted by the :created_at property if it is available and there are no
  # conditions on the query - eg User.all, User.first  As this is a minor use case it is recommended
  # to use the CouchFoo#default_sort macro that applies a default sort order to the model each time
  # it's retrieved from the database.  This way you can set default_sort :created_at and not worry
  # about hitting the problem again.
  #
  # With CouchDB the price to pay for inserting data into an indexed view isn't paid at insertion
  # time like MySQL and friends, but at the point of next retrieving that view (although it's 
  # possible to override this in order to sacrifice performance for accuracy).  As such you can
  # either pay the performance cost when accessing the view (which might be ok if the view gets
  # used a lot but not if a million applicable documents have been added since the last view) or
  # add an external process which gets called everytime a document is created in CouchDB.  More of 
  # this is outlined in the CouchFoo#find documentation
  # 
  # Connecting to the database is done in a way similar to ActiveRecord where the database is
  # inherited by each subclass unless overridden.  In CouchFoo you use the call set_database method
  # with a host and database name.  As there's no database connection to be maintained sharding data
  # is very efficient and some applications even use one database per user.
  # 
  # If using rails, for now you need to specify your own initializer to make the default database
  # connection.  This will be brought inline with rails in the future, using a couchdb.yml 
  # configuration file or similar.  But for now an initializer file in config/initializers like the 
  # following will do the trick:
  #
  #   CouchFoo::Base.set_database(:host => "http://localhost:5984", :database => "mydatabase")
  #   CouchFoo::Base.logger = Rails.logger
  #
  # A few tidbits:
  # * When specifying associations you still need to specify the object_id and object_type (if using polymorphic association) properties.  We have this automated as part of the association macro soon  
  # * validates_uniqueness_of has had the :case_sensitive option dropped
  # * Because there's no SQL there's no SQL finder methods but equally there's no SQL injection to worry about.  You should still sanitize output when displaying back to the user though because you will still be vunerable to JS attacks etc.
  # * Some operations are more efficient than relational databases, others less so.  See the performance section for more details on this
  # * Every so often the database will need compacting to recover space lost to old document revisions.  More importantly initial indications show un-compacted databases can effect performance.  See http://wiki.apache.org/couchdb/Compaction for more details on this.
  #
  # The following things are not in this implementation (but are in ActiveRecord):
  # * :include - Although the finders and associations allow this option the actual implementation is yet to be written
  # * Timezones
  # * Aggregations
  # * Fixtures and general testing support
  # * Query cache
  # 
  # == Properties
  # 
  # Couch Foo objects specify their properties through the use of property definitions inside the 
  # model itself.  This is unlike ActiveRecord (but similar to DataMapper).  As the underlying 
  # database document is stored in JSON (String, Integer, Float, Time, DateTime, Date and 
  # Boolean/TrueClass are the available types) there are a few differences between CouchFoo and
  # ActiveRecord.  The following table highlights any changes that will need to be made to 
  # model types:
  # 
  #  ActiveRecord type | CouchFoo type
  #  ------------------+---------------------------------
  #  #Text             | String
  #  #Decimal          | Float
  #  #Timestamp        | Time
  #  #Binary           | Attachment (not yet implemented)
  #
  # An example of a model is as follows:
  #
  #   class Address < CouchFoo::Base
  #     property :number, Integer
  #     property :street, String
  #     property :postcode # Any generic type is fine as long as .to_json can be called on it
  #   end
  #  
  # == Creation
  #
  # Couch Foo accept constructor parameters either in a hash or as a block. The hash method is 
  # especially useful when you're receiving the data from somewhere else, like an HTTP request. 
  # It works like this:
  #
  #   user = User.new(:name => "David", :occupation => "Code Artist")
  #   user.name # => "David"
  #
  # You can also use block initialization:
  #
  #   user = User.new do |u|
  #     u.name = "David"
  #     u.occupation = "Code Artist"
  #   end
  #
  # And of course you can just create a bare object and specify the attributes after the fact:
  #
  #   user = User.new
  #   user.name = "David"
  #   user.occupation = "Code Artist"
  #
  # == Conditions
  #
  # Conditions are specified as a Hash.  This is different from ActiveRecord where they can be
  # specified as a String, Array or Hash.  Example:
  #
  #   class User < ActiveRecord::Base
  #     def self.authenticate_safely_simply(user_name, password)
  #       find(:first, :conditions => { :user_name => user_name, :password => password })
  #     end
  #   end
  # 
  # A range may be used in the hash to find documents between two values:
  #
  #   Student.find(:all, :conditions => { :grade => 9..12 })
  #
  # A startkey or endkey can be used to find documents where the documents exceed or preceed the 
  # value.  A key is needed here so CouchFoo knows which property to apply the startkey to:
  #
  #   Student.find(:all, :use_key => :grade, :startkey => 80)
  #
  # Finally an array may be used in the hash to use find records just matching those values.  This 
  # operation requires CouchDB > 0.8 though:
  #
  #   Student.find(:all, :conditions => { :grade => [9,11,12] })
  #
  # == Overwriting default accessors
  #
  # All column values are automatically available through basic accessors on the Active Record object, but sometimes you
  # want to specialize this behavior. This can be done by overwriting the default accessors (using the same
  # name as the attribute) and calling <tt>read_attribute(attr_name)</tt> and <tt>write_attribute(attr_name, value)</tt> to actually change things.
  # Example:
  #
  #   class Song < ActiveRecord::Base
  #     # Uses an integer of seconds to hold the length of the song
  #
  #     def length=(minutes)
  #       write_attribute(:length, minutes.to_i * 60)
  #     end
  #
  #     def length
  #       read_attribute(:length) / 60
  #     end
  #   end
  #
  # You can alternatively use <tt>self[:attribute]=(value)</tt> and <tt>self[:attribute]</tt> instead of <tt>write_attribute(:attribute, value)</tt> and
  # <tt>read_attribute(:attribute)</tt> as a shorter form.
  #
  # == Attribute query methods
  #
  # In addition to the basic accessors, query methods are also automatically available on the Active Record object.
  # Query methods allow you to test whether an attribute value is present.
  #
  # For example, an Active Record User with the <tt>name</tt> attribute has a <tt>name?</tt> method that you can call
  # to determine whether the user has a name:
  #
  #   user = User.new(:name => "David")
  #   user.name? # => true
  #
  #   anonymous = User.new(:name => "")
  #   anonymous.name? # => false
  #
  # == Accessing attributes before they have been typecasted
  #
  # Sometimes you want to be able to read the raw attribute data without having the property typecast run its course first.
  # That can be done by using the <tt><attribute>_before_type_cast</tt> accessors that all attributes have. For example, if your Account model
  # has a <tt>balance</tt> attribute, you can call <tt>account.balance_before_type_cast</tt> or <tt>account.id_before_type_cast</tt>.
  #
  # This is especially useful in validation situations where the user might supply a string for an integer field and you want to display
  # the original string back in an error message. Accessing the attribute normally would typecast the string to 0, which isn't what you
  # want.
  #
  # == Dynamic attribute-based finders
  #
  # Dynamic attribute-based finders are a cleaner way of getting (and/or creating) objects by simple queries. They work by
  # appending the name of an attribute to <tt>find_by_</tt> or <tt>find_all_by_</tt>, so you get finders like <tt>Person.find_by_user_name</tt>,
  # <tt>Person.find_all_by_last_name</tt>, and <tt>Payment.find_by_transaction_id</tt>. So instead of writing
  # <tt>Person.find(:first, :conditions => {:user_name => user_name})</tt>, you just do <tt>Person.find_by_user_name(user_name)</tt>.
  # And instead of writing <tt>Person.find(:all, :conditions => {:last_name => last_name})</tt>, you just do <tt>Person.find_all_by_last_name(last_name)</tt>.
  #
  # It's also possible to use multiple attributes in the same find by separating them with "_and_", so you get finders like
  # <tt>Person.find_by_user_name_and_password</tt> or even <tt>Payment.find_by_purchaser_and_state_and_country</tt>. So instead of writing
  # <tt>Person.find(:first, :conditions => {:user_name => user_name, :password => password})</tt>, you just do
  # <tt>Person.find_by_user_name_and_password(user_name, password)</tt>.
  #
  # It's even possible to use all the additional parameters to find. For example, the full interface for <tt>Payment.find_all_by_amount</tt>
  # is actually <tt>Payment.find_all_by_amount(amount, options)</tt>. And the full interface to <tt>Person.find_by_user_name</tt> is
  # actually <tt>Person.find_by_user_name(user_name, options)</tt>. So you could call <tt>Payment.find_all_by_amount(50, :order => :created_at)</tt>.
  #
  # The same dynamic finder style can be used to create the object if it doesn't already exist. This dynamic finder is called with
  # <tt>find_or_create_by_</tt> and will return the object if it already exists and otherwise creates it, then returns it. Protected 
  # attributes won't be set unless they are given in a block. For example:
  #
  #   # No 'Summer' tag exists
  #   Tag.find_or_create_by_name("Summer") # equal to Tag.create(:name => "Summer")
  #
  #   # Now the 'Summer' tag does exist
  #   Tag.find_or_create_by_name("Summer") # equal to Tag.find_by_name("Summer")
  #
  #   # Now 'Bob' exist and is an 'admin'
  #   User.find_or_create_by_name('Bob', :age => 40) { |u| u.admin = true }
  #
  # Use the <tt>find_or_initialize_by_</tt> finder if you want to return a new record without saving it first. Protected attributes 
  # won't be setted unless they are given in a block. For example:
  #
  #   # No 'Winter' tag exists
  #   winter = Tag.find_or_initialize_by_name("Winter")
  #   winter.new_record? # true
  #
  # To find by a subset of the attributes to be used for instantiating a new object, pass a hash instead of
  # a list of parameters. For example:
  #
  #   Tag.find_or_create_by_name(:name => "rails", :creator => current_user)
  #
  # That will either find an existing tag named "rails", or create a new one while setting the user that created it.
  #
  # == Saving arrays, hashes, and other non-mappable objects in text columns
  #
  # CouchFoo will try and serialize any types that are not specified in properties by calling .to_json on the object
  # This means its not only possible to store arrays and hashes (with no extra work required) but also any generic type
  # you care to define, so long as it has a .to_json method defined.  Example:
  #
  #   class User < CouchFoo::Base
  #     property :name, String
  #     property :house # Can be any object so long as it responds to .to_json
  #   end
  #
  # == Inheritance
  #
  # Couch Foo allows inheritance by storing the name of the class in a column that by default is named "type" (can be changed
  # by overwriting <tt>Base.inheritance_column</tt>). This means that an inheritance looking like this:
  #
  #   class Company < ActiveRecord::Base; end
  #   class Firm < Company; end
  #   class Client < Company; end
  #   class PriorityClient < Client; end
  #
  # When you do <tt>Firm.create(:name => "37signals")</tt>, this record will be saved in the companies table with type = "Firm". You can then
  # fetch this row again using <tt>Company.find(:first, {:name => "37signals"})</tt> and it will return a Firm object.
  #
  # If you don't have a type column defined in your table, inheritance won't be triggered. In that case, it'll work just
  # like normal subclasses with no special magic for differentiating between them or reloading the right type with find.
  #
  # == Connection to multiple databases in different models
  #
  # Connections are usually created through CouchFoo::Base.set_database and retrieved by CouchFoo::Base.database
  # All classes inheriting from CouchFoo::Base will use this connection. But you can also set a class-specific connection.
  # For example, if Course is an CouchFoo::Base, but resides in a different database, you can just say <tt>Course.set_database url</tt>
  # and Course and all of its subclasses will use this connection instead.
  #
  # == Performance
  #
  # CouchDB operates via a RESTful interface and so isn't as efficient as a local database when 
  # running over a local socket.  This is due to the TCP/IP overhead.  But given any serious 
  # application runs a separate database and application server then it is unfair to judge 
  # CouchDB on this alone. 
  #
  # Generally speaking CouchDB performs as well as or better than relational databases when it already
  # has the document in memory.  If it doesn't it performs worse as it must first find the document
  # and submit the new version (as there's no structure to documents it can't update fields on an 
  # add-hoc basis, it must have the whole document).  This makes class operations such as update_all
  # less efficient.  If your application is high load and uses these excessively you may wish to
  # consider other databases.  On the flip side if you have lots of documents in memory and wish to
  # update them all, using bulk_save is an excellent way to make performance gains.
  # 
  # Below is a list of operations where the performance differs from ActiveRecord.  More notes are 
  # available in the functions themselves:
  #
  # * class.find - when using list of ids is O(n) rather than O(1) if not on CouchDB 0.9
  # * class.create - O(1) rather than O(n) if using bulk_save
  # * class.delete - O(n) rather than O(1) so less efficient for > 1 document
  # * class.update_all - O(n+1) rather than O(1)
  # * class.delete_all - O(2n) rather than O(1)
  # * class.update_counters - O(2) rather than O(1)
  # * class.increment_counter - O(2) rather than O(1)
  # * class.decrement_counter - O(2) rather than O(1)
  # * save, save!, update_attribute, update_attributes, update_attributes!, increment!, decrement!, 
  # toggle! - if using bulk_save then O(1) rather than O(n)
  
  class Base
    # Accepts a logger conforming to the interface of Log4r or the default Ruby 1.8+ Logger class, 
    # which is then passed on to any new database connections made and which can be retrieved on 
    # both a class and instance level by calling +logger+.
    cattr_accessor :logger, :instance_writer => false
    
    # Accessor for the name of the prefix string to prepend to every document name. So if set to 
    # "basecamp_", all document names will be named like "basecamp_project", "basecamp_person", etc. 
    # This is a convenient way of creating a namespace for documents in a shared database. By 
    # default, the prefix is the empty string.
    cattr_accessor :document_name_prefix, :instance_writer => false
    @@document_name_prefix = ""

    # Works like +document_name_prefix+, but appends instead of prepends (set to "_basecamp" gives 
    # "projects_basecamp", "people_basecamp"). By default, the suffix is the empty string.
    cattr_accessor :document_name_suffix, :instance_writer => false
    @@document_name_suffix = ""
    
    # Properties that cannot be altered by the user.  By default this includes _id, _rev (both 
    # CouchDB internals) and ruby_class (used by CouchFoo to match a CouchDB document to a ruby 
    # class)
    cattr_accessor :unchangeable_property_names, :instance_writer => false
    @@unchangeable_property_names = [:_id, :_rev, :ruby_class]
    
    # Determines whether to use Time.local (using :local) or Time.utc (using :utc) when pulling dates 
    # and times from the database.  This is set to :local by default.
    cattr_accessor :default_timezone, :instance_writer => false
    @@default_timezone = :local
    
    class << self # Class Methods
      # CouchDB has a concept called views which show a subset of documents in the database subject to criteria.
      # The documents selected are chosen according to a map function and an optional reduce function.  
      # The later is useful for example, to count all the documents that have been matched by the initial map function.
      # CouchFoo automatically creates views for each of the data models you use as you require them.  
      # For example take the class House.  The first House.find(:id) will create a House design document with a view 
      # that exposes the id of the house as a key - any house can then be selected on this.  If you then do a query 
      # for a certain colour house, ie House.find_all_by_colour("red") then a view that exposes the house colour as
      # a key will be added to the design document.  So as you perform new queries the design document for a model 
      # is updated so you are always accessing via an 'indexed' approach.  This should be transparent to the developer
      # but the resulting views can be seen by looking up the design document in the database.
      #
      # CouchFoo cannot handle automatic view generation for the case where both an :order and :limit should be 
      # applied to a result set.  This is because the ordering is performed after retrieving data from CouchDB 
      # whereas the limit is applied at the database level.  As such if you were limiting to 5 results
      # and ordering on a property you would get the same 5 results in a different order rather than the first 5
      # and last 5 results for that data type.  To overcome this restriction either define the property you wish
      # to order on in the :use_key option (make sure you add conditions you're using in here as well) or create your 
      # own views using CouchFoo#view.  You can then use the :descending => true to reverse the results order.
      #
      # There is a slight caveat to the way views work in CouchDB.  The index is only updated each time a view
      # is accessed (although this can be overridden using :update).  This is both good and bad.  Good in the 
      # sense you don't pay the price at insertion time, bad in the sense you pay when accessing the view the
      # next time (although this can be more efficient).  The simple solution is to write a script that 
      # periodically calls the view to update the index as described on the CouchDB site in this FAQ: 
      # http://wiki.apache.org/couchdb/Frequently_asked_questions#update_views_more_often  Needless to say 
      # creating a new view on a large dataset is expensive but this is no different from creating an index 
      # on a large MySQL table (although in general it's a bit slower as all the documents are in one place
      # rather than split into tables)
      #
      # It is possible to perform unindexed queries by using slow views, although this is not recommended 
      # for production use. Like MySQL performing unindexed lookups is very inefficient on large datasets.
      #
      # One final point to note is we're used to using relational databases that have auto-incrementing keys.
      # Therefore the newest rows added to the database have the highest key value (some databases go back
      # and fill in the missing/deleted keys after a restart but generally speaking...) and are therefore shown last
      # in lists on the front end.  When using CouchDB each item is allocated a UUID which varies massively
      # depending on time, computer IP etc.  Therefore it is likely that adding a new item to a page via AJAX
      # will add the item to the bottom of the list but when the page is reloaded it occurs in the middle
      # somewhere.  This is very confusing for users so it is therefore recommended that you sort items on a 
      # :created_at field by default (see CouchFoo#default_sort).
      #
      # More information can be found on CouchDB views at: http://wiki.apache.org/couchdb/Introduction_to_CouchDB_views
      #
      # CouchFoo operates with four different retrieval approaches:
      #
      # * Find by id - This can either be a specific id (1), a list of ids (1, 5, 6), or an array of ids ([5, 6, 10]).
      #   If no record can be found for all of the listed ids, then DocumentNotFound will be raised.  This only
      #   accepts the :conditions and :readonly options.  Note when using a list/array of ids the lookup is O(n)
      #   efficiency rather than O(1) (as with ActiveRecord) if using CouchDB<0.9 
      # * Find first - This will return the first record matched by the options used. These options can either be 
      #   specific conditions or merely an order. If no record can be matched, +nil+ is returned. Use
      #   <tt>Model.find(:first, *args)</tt> or its shortcut <tt>Model.first(*args)</tt>.  It is recommended you
      #   use CouchFoo#default_sort on the model if you wish to use this with ordering.
      # * Find last - This will return the last record matched by the options used. These options can either be 
      #   specific conditions or merely an order. If no record can be matched, +nil+ is returned. Use
      #   <tt>Model.find(:last, *args)</tt> or its shortcut <tt>Model.last(*args)</tt>.  It is recommended you
      #   use CouchFoo#default_sort on the model if you wish to use this with ordering.
      # * Find all - This will return all the records matched by the options used.
      #   If no records are found, an empty array is returned. Use
      #   <tt>Model.find(:all, *args)</tt> or its shortcut <tt>Model.all(*args)</tt>.
      #
      # All approaches accept an options hash as their last parameter.
      # 
      # ==== Attributes
      #
      # NOTE: Only :conditions and :readonly are available on find by id lookups
      #
      # * <tt>:conditions</tt> - This can only take a Hash of options to match, not SQL fragments 
      #   like ActiveRecord.  For example :conditions => {:size = 6, :price => 30..80} or 
      #   :conditions => {:size => [6, 8, 10]}  <b>Note</b> when using the later approach and
      #   specifying a discrete list CouchDB doesn't support ranges in the same query
      # * <tt>:order</tt> - With a field name sorts on that field.  This is applied after the results
      #   are returned from the database so should not be used with :limit and is fairly pointless
      #   with find(:first) and find(:last) types.  See CouchFoo#view for how to create views
      #   that can be sorted ActiveRecord style
      # * <tt>:include</tt> - not implemented yet
      # * <tt>:limit</tt> - an integer determining the limit on the number of rows that should be 
      #   returned.  Take caution if using with :order (read notes in :order and section header)
      # * <tt>:offset</tt> - An integer determining the offset from where the rows should be fetched. 
      #   So at 5, it would skip rows 0 through 4.  This is the same as :skip listed below in the
      #   further options.  Note: This is not particulary efficient in CouchDB
      # * <tt>:update</tt> - If set to false will not update the view so although the access will be
      #   faster some of the data may be out of date.  Recommended if you are managing view updation
      #   independently
      # * <tt>:readonly</tt> - Mark the returned documents read-only so they cannot be saved or updated.
      # * <tt>:view_type</tt> - by default views are created for queries where there is no view (this
      #   is equivalent to no index on the column in MySQL) to keep lookups efficient.  However
      #   by passing :view_type => :slow a CouchDB slow query will be performed.  As the name suggests
      #   these are slow and should only be used in development not production.  Be sure to read the
      #   note above on how CouchDB indexing works and responsabilites of the developer.
      # * <tt>:use_key</tt> - The key to emit in the view.  The key is used for selection and ordering
      #   so is a good way to order results and limit to a certain quantity, or to find results that
      #   are greater or less than a certain value (in combination with :startkey, :endkey).  Normally
      #   this value is automatically determined when using :conditions.  As such when using in
      #   combination with :conditions option this must contain both the items you would like in the key 
      #   and the items you're using in the conditions.  For example:
      #   User.find(:all, :use_key => [:name, :administrator], :conditions => {:administrator => true})
      # * <tt>:startkey</tt> - Used to find all documents from this value up, for example 
      #   User.find(:all, :startkey => 20)  This needs to be used with a custom map function where 
      #   the user has chosen the exposing key for it to be meaningful.
      # * <tt>:endkey</tt> - As :startkey but documents upto that key rather than from it
      # * <tt>:return_json</tt> - If you are emitting something other than the document as the value
      #   on a custom map function you may wish to return the raw JSON as instantiating objects may not
      #   be possible.  Using this option will ignore any :order or :readonly settings
      # * <tt>Further options</tt> - The CouchDB view options :descending, :group, :group_level, 
      #   :skip, :keys, :startkey_docid and :endkey_docid are supported on views but they 
      #   are unlikely to be required unless the developer is specifying their own map or reduce function.
      #   Note some of these require CouchDB 0.9 (see CouchDB wiki for list)
      #
      # ==== Examples
      #
      #   # find by id
      #   Person.find(1)       # returns the object for ID = 1
      #   Person.find(1, 2, 6) # returns an array for objects with IDs in (1, 2, 6)
      #   Person.find([7, 17]) # returns an array for objects with IDs in (7, 17)
      #   Person.find([1])     # returns an array for the object with ID = 1
      #   Person.find(1, :conditions => {:administrator => 1})
      #
      #   Unlike ActiveRecord order will be maintained on multiple id selection but the operation
      #   is not as efficient as there is no multiple get from the database 
      #
      #   # find first
      #   Person.find(:first) # returns the first object fetched by key (so this is unlikely to be
      #   the oldest person document in the database)
      #   Person.find(:first, :use_key => :created_at) # Finds earliest person but at the expense of 
      #   creating a new view
      #   Person.find(:first, :use_key => :created_at, :startkey => "2009/09/01")) # Finds 1st person
      #   since 1st September 2009 but uses the same index as above
      #
      #   # find last
      #   Person.find(:last) # returns the last object, again may not be what's expected
      #   Person.find(:last, :conditions => { :user_name => user_name}) 
      #
      #   # find all
      #   Person.find(:all) # returns an array of objects
      #   Person.find(:all, :conditions => {:category => "Article"}, :limit => 50)
      #   Person.find(:all, :use_key => [:name, :category], :conditions => {:category => "Article"}, :limit => 50)
      #   # Creates a name, category index and finds the first 50 people ordered by name with a category of "Article"
      def find(*args)
        options = args.extract_options!
        validate_find_options(options)
        set_readonly_option!(options)

        case args.first
          when :first then find_initial(options)
          when :last  then find_last(options)
          when :all   then find_every(options)
          else             find_from_ids(args, options)
        end
      end
      
      # A convenience wrapper for <tt>find(:first, *args)</tt>. You can pass in all the
      # same arguments to this method as you can to <tt>find(:first)</tt>.
      def first(*args)
        find(:first, *args)
      end

      # A convenience wrapper for <tt>find(:last, *args)</tt>. You can pass in all the
      # same arguments to this method as you can to <tt>find(:last)</tt>.
      def last(*args)
        find(:last, *args)
      end

      # This is an alias for find(:all).  You can pass in all the same arguments to this method as you can
      # to find(:all)
      def all(*args)
        find(:all, *args)
      end
      
      # Checks whether a document exists in the database that matches conditions given.  These conditions
      # can either be a key to be found, or a condition to be matched like using CouchFoo#find.
      #
      # ==== Examples
      #   Person.exists?('5a1278b3c4e')
      #   Person.exists?(:name => "David")
      def exists?(id_or_conditions)
        if (id_or_conditions.is_a?(Hash))
          !find(:first, :conditions => {:ruby_class => document_class_name}.merge(id_or_conditions)).nil?
        else
          !find(id_or_conditions, :conditions => {:ruby_class => document_class_name}).nil? rescue false
        end
      end
      
      # Creates an object (or multiple objects) and saves it to the database, if validations pass.
      # The resulting object is returned whether the object was saved successfully to the database or not.
      #
      # The +attributes+ parameter can be either be a Hash or an Array of Hashes.  These Hashes describe the
      # attributes on the objects that are to be created.
      #
      # If using bulk save this operation is O(1) rather than O(n) so much more efficient
      #
      # ==== Examples
      #   # Create a single new object
      #   User.create(:first_name => 'Jamie')
      #
      #   # Create an Array of new objects
      #   User.create([{ :first_name => 'Jamie' }, { :first_name => 'Jeremy' }])
      #
      #   # Create a single object and pass it into a block to set other attributes.
      #   User.create(:first_name => 'Jamie') do |u|
      #     u.is_admin = false
      #   end
      #
      #   # Creating an Array of new objects using a block, where the block is executed for each object:
      #   User.create([{ :first_name => 'Jamie' }, { :first_name => 'Jeremy' }]) do |u|
      #     u.is_admin = false
      #   end
      def create(attributes = nil, &block)
        if attributes.is_a?(Array)
          attributes.collect { |attr| create(attr, &block) }
        else
          object = new(attributes)
          yield(object) if block_given?
          object.save
          object
        end
      end
      
      # Updates an object (or multiple objects) and saves it to the database, if validations pass.
      # The resulting object is returned whether the object was saved successfully to the database or not.
      # 
      # ==== Attributes
      #
      # * +id+ - This should be the id or an array of ids to be updated.
      # * +attributes+ - This should be a Hash of attributes to be set on the object, or an array of Hashes.
      #
      # ==== Examples
      #
      #   # Updating one record:
      #   Person.update('6180e9a0-cdca-012b-14a5-001a921a2bec', { :user_name => 'Samuel', :group => 'expert' })
      #
      #   # Updating multiple records:
      #   people = { '6180e9a0-cdca-012b-14a5-001a921a2bec' => { "first_name" => "David" }, 'e6f6a870-cdc9-012b-14a3-001a921a2bec' => { "first_name" => "Jeremy" } }
      #   Person.update(people.keys, people.values)
      def update(id, attributes)
        if id.is_a?(Array)
          idx = -1
          id.collect { |one_id| idx += 1; update(one_id, attributes[idx]) }
        else
          object = find(id)
          object.update_attributes(attributes)
          object
        end
      end
      
      # Delete an object (or multiple objects) where the _id and _rev given match the record.  No
      # callbacks are fired off executing so this is an efficient method of deleting documents that
      # don't need cleaning up after or other actions to be taken.
      #
      # This operations is O(n) compared to O(1) so is less efficient than ActiveRecord when deleting 
      # more than one document
      #
      # Objects are _not_ instantiated with this method.
      #
      # ==== Attributes
      #
      # * +id+ - Can be either a String or an Array of Strings.
      #
      # ==== Examples
      #
      #   # Delete a single object
      #   Todo.delete('6180e9a0-cdca-012b-14a5-001a921a2bec', '12345678')
      #
      #   # Delete multiple objects
      #   ids = ['6180e9a0-cdca-012b-14a5-001a921a2bec', 'e6f6a870-cdc9-012b-14a3-001a921a2bec']
      #   revs = ['12345678', '12345679']
      #   Todo.delete(ids, revs)
      def delete(id, rev)
        if id.is_a?(Array)
          idx = -1
          id.collect {|i| idx += 1; delete(i, rev[idx])}
        else
          database.delete({"_id" => id, "_rev" => rev})
          true
        end
      end
    
      # Destroy an object (or multiple objects) that has the given id.  Unlike delete this doesn't
      # require a _rev as the object if found, created from the attributes and then destroyed.  As 
      # such all callbacks and filters are fired off before the object is deleted.  This method is 
      # the same in efficiency terms as CouchFoo#delete unlike in ActiveRecord where delete is more
      # efficient
      #
      # ==== Examples
      #
      #   # Destroy a single object
      #   Todo.destroy('6180e9a0-cdca-012b-14a5-001a921a2bec')
      #
      #   # Destroy multiple objects
      #   Todo.destroy(['6180e9a0-cdca-012b-14a5-001a921a2bec', 'e6f6a870-cdc9-012b-14a3-001a921a2bec'])
      def destroy(id)
        if id.is_a?(Array)
          id.map { |one_id| destroy(one_id) }
        else
          find(id).destroy
        end
      end
    
      # Updates all records with details given if they match a set of conditions supplied.  Even though
      # this uses a bulk save and immediately commits it must first find the relevant documents so is
      # O(n+1) rather than O(1)
      #
      # ==== Attributes
      #
      # * +updates+ - A hash of attributes to update
      # * +options+ - As CouchFoo#find.  Unlike ActiveRecord :order and :limit cannot be used togther
      #               unless via a custom view (see notes in CouchFoo#find)
      #
      # ==== Examples
      #
      #   # Update all billing objects with the 3 different attributes given
      #   Billing.update_all( :category => 'authorized', :approved => 1, :author => 'David' )
      #
      #   # Update records that match our conditions
      #   Billing.update_all( {:author = 'David'}, :conditions => {:title => 'Rails'} )
      def update_all(updates, options = {})
        find(:all, options).each {|d| d.update_attributes(updates, true)}
        database.commit
      end
    
      # Destroys the records matching +conditions+ by instantiating each record and calling the destroy method.
      # This means at least 2*N database queries to destroy N records, so avoid destroy_all if you are deleting
      # many records. If you want to simply delete records without worrying about dependent associations or
      # callbacks, use the much faster +delete_all+ method instead.
      #
      # ==== Attributes
      #
      # * +conditions+ - Conditions are specified the same way as with +find+ method.
      #
      # ==== Example
      #
      #   Person.destroy_all "last_login < '2004-04-04'"
      #
      # This loads and destroys each person one by one, including its dependent associations and before_ and
      # after_destroy callbacks.
      def destroy_all(conditions = nil)
        find(:all, :conditions => conditions).each { |object| object.destroy }
      end

      # Currently there is no way to do selective delete in CouchDB so this simply defers to
      # CouchFoo#destroy_all for API compatability with ActiveRecord
      #
      # This operations is O(2n) compared to O(1) so much less efficient than ActiveRecord
      def delete_all(conditions = nil)
        destroy_all(conditions)
      end
      
      # A generic "counter updater" implementation, intended primarily to be
      # used by increment_counter and decrement_counter, but which may also
      # be useful on its own.  Unlike ActiveRecord this does not update the
      # database directly but has to first find the record.  Therefore updates
      # require 2 database requests.
      #
      # ==== Attributes
      #
      # * +id+ - The id of the object you wish to update a counter on.
      # * +counters+ - An Array of Hashes containing the names of the fields
      #   to update as keys and the amount to update the field by as values.
      #
      # ==== Examples
      #
      #   # For the Post with id of '5aef343ab2', decrement the comment_count by 1, and
      #   # increment the action_count by 1
      #   Post.update_counters 'aef343ab2', :comment_count => -1, :action_count => 1
      def update_counters(id, counters)
        record = find(id)
        counters.each do |key,value|
          record.increment(key, value)
        end
        record.save
      end

      # Increment a number field by one, usually representing a count.  Unlike ActiveRecord this 
      # does not update the database directly but has to first find the record.  Therefore updates
      # are O(2) rather than O(1)
      #
      # ==== Attributes
      #
      # * +counter_name+ - The name of the field that should be incremented.
      # * +id+ - The id of the object that should be incremented.
      #
      # ==== Examples
      #
      #   # Increment the post_count property for the record with an id of 'aef343ab2'
      #   DiscussionBoard.increment_counter(:post_count, 'aef343ab2')
      def increment_counter(counter_name, id)
        update_counters(id, {counter_name => 1})
      end

      # Decrement a number field by one, usually representing a count.  This works the same as 
      # increment_counter but reduces the property value by 1 instead of increasing it.  Unlike 
      # ActiveRecord this does not update the database directly but has to first find the record.  
      # Therefore updates are O(2) rather than O(1)
      #
      # ==== Attributes
      #
      # * +counter_name+ - The name of the field that should be decremented.
      # * +id+ - The id of the object that should be decremented.
      #
      # ==== Examples
      #
      #   # Decrement the post_count property for the record with an id of 'aef343ab2'
      #   DiscussionBoard.decrement_counter(:post_count, 'aef343ab2')
      def decrement_counter(counter_name, id)
        update_counters(id, {counter_name => -1})
      end
    
      # Attributes named in this macro are protected from mass-assignment,
      # such as <tt>new(attributes)</tt>,
      # <tt>update_attributes(attributes)</tt>, or
      # <tt>attributes=(attributes)</tt>.
      #
      # Mass-assignment to these attributes will simply be ignored, to assign
      # to them you can use direct writer methods. This is meant to protect
      # sensitive attributes from being overwritten by malicious users
      # tampering with URLs or forms.
      #
      #   class Customer < CouchFoo::Base
      #     attr_protected :credit_rating
      #   end
      #
      #   customer = Customer.new("name" => David, "credit_rating" => "Excellent")
      #   customer.credit_rating # => nil
      #   customer.attributes = { "description" => "Jolly fellow", "credit_rating" => "Superb" }
      #   customer.credit_rating # => nil
      #
      #   customer.credit_rating = "Average"
      #   customer.credit_rating # => "Average"
      #
      # To start from an all-closed default and enable attributes as needed,
      # have a look at +attr_accessible+.
      def attr_protected(*attributes)
        write_inheritable_attribute("attr_protected", Set.new(attributes.map(&:to_s)) + (protected_attributes || []))
      end
      
      # Returns an array of all the attributes that have been protected from mass-assignment.
      def protected_attributes # :nodoc:
        read_inheritable_attribute("attr_protected")
      end
      
      # Specifies a white list of model attributes that can be set via
      # mass-assignment, such as <tt>new(attributes)</tt>,
      # <tt>update_attributes(attributes)</tt>, or
      # <tt>attributes=(attributes)</tt>
      #
      # This is the opposite of the +attr_protected+ macro: Mass-assignment
      # will only set attributes in this list, to assign to the rest of
      # attributes you can use direct writer methods. This is meant to protect
      # sensitive attributes from being overwritten by malicious users
      # tampering with URLs or forms. If you'd rather start from an all-open
      # default and restrict attributes as needed, have a look at
      # +attr_protected+.
      #
      #   class Customer < CouchFoo::Base
      #     attr_accessible :name, :nickname
      #   end
      #
      #   customer = Customer.new(:name => "David", :nickname => "Dave", :credit_rating => "Excellent")
      #   customer.credit_rating # => nil
      #   customer.attributes = { :name => "Jolly fellow", :credit_rating => "Superb" }
      #   customer.credit_rating # => nil
      #
      #   customer.credit_rating = "Average"
      #   customer.credit_rating # => "Average"
      def attr_accessible(*attributes)
        write_inheritable_attribute("attr_accessible", Set.new(attributes.map(&:to_s)) + (accessible_attributes || []))
      end
      
      # Returns an array of all the attributes that have been made accessible to mass-assignment.
      def accessible_attributes # :nodoc:
        read_inheritable_attribute("attr_accessible")
      end
      
      # Attributes listed as readonly can be set for a new record, but will be ignored in database 
      # updates afterwards
      def attr_readonly(*attributes)
        write_inheritable_attribute("attr_readonly", Set.new(attributes.map(&:to_s)) + (readonly_attributes || []))
      end
      
      # Returns an array of all the attributes that have been specified as readonly
      def readonly_attributes
        read_inheritable_attribute("attr_readonly")
      end
      
      # Guesses the document name (in forced lower-case) based on the name of the class in the 
      # inheritance hierarchy descending directly from CouchFoo::Base. So if the hierarchy looks
      # like: Reply < Message < CouchFoo::Base, then Reply is used as the document name. The 
      # rules used to do the guess are handled by the Inflector class in Active Support, which 
      # knows almost all common English inflections. You can add new inflections in 
      # config/initializers/inflections.rb.
      #
      # Nested classes and enclosing modules are not considered.
      #
      # ==== Example
      #
      #   class Invoice < CouchFoo::Base; end;
      #   file                  class               document_name
      #   invoice.rb            Invoice             invoice
      #
      # Additionally, the class-level +document_name_prefix+ is prepended and the
      # +document_name_suffix+ is appended.  So if you have "myapp_" as a prefix,
      # the document name guess for an Invoice class becomes "myapp_invoices".
      #
      # You can also overwrite this class method to allow for unguessable
      # links, such as a Mouse class with a link to a "mice" document. Example:
      #
      #   class Mouse < CouchFoo::Base
      #     set_document_name "mice"
      #   end
      def document_class_name
        reset_document_class_name
      end
      
      def reset_document_class_name
        name = self.name
        unless self == base_class
          name = superclass.document_class_name
        end
        
        doc_class_name = "#{document_name_prefix}#{name}#{document_name_suffix}"
        set_document_class_name(doc_class_name)
        doc_class_name
      end

      # Sets the document class name to use to the given value, or (if the value
      # is nil or false) to the value returned by the given block.
      #
      #   class Project < CouchFoo::Base
      #     set_document_class_name "project"
      #   end
      def set_document_class_name(value = nil, &block)
        define_attr_method :document_class_name, value, &block
      end
      alias :document_class_name= :set_document_class_name
      
      # Defines the propety name for use with single table inheritance
      # -- can be set in subclasses like so: self.inheritance_column = "type_id"
      def inheritance_column
        @inheritance_column ||= "type".freeze
      end
      
      # Sets the name of the inheritance column to use to the given value,
      # or (if the value # is nil or false) to the value returned by the
      # given block.
      #
      #   class Project < CouchFoo::Base
      #     set_inheritance_column do
      #       original_inheritance_column + "_id"
      #     end
      #   end
      def set_inheritance_column(value = nil, &block)
        define_attr_method :inheritance_column, value, &block
      end
      alias :inheritance_column= :set_inheritance_column

      # Set a property for the document.  These can be passed a type and options hash.  If no type
      # is passed a #to_json method is called on the ruby object and the result stored in the 
      # database.  When it is retrieved from the database a class.from_json(json) method is called
      # on it or if that doesn't exist it just uses the value (more on this at 
      # http://www.rowtheboat.com/archives/35).  If a type is passed then the object is cast before 
      # storing in the database.  This does not guarantee that the object is the correct type (use 
      # the validaters for that), it merely tries to convert the current type to the desired one
      # - for example:
      # '123' => 123 # useful
      # 'a' => 0 # probably not desired behaviour
      # The later would fail with a validator
      # 
      # The options hash supports:
      # default - the default value for the attribute to be initalized to
      # 
      # ==== Example:
      # 
      # class Invoice < CouchFoo::Base
      #   property :number, Integer
      #   property :paid, TrueClass, :default => false
      #   property :notes, String
      #   property :acl # or acl, Object is equivalent
      #   property :price, Price
      # end  
      def property(name, type = Object, options = {})
        logger.warn("Using type as a property name may issue unexpected behaviour") if name == :type
        properties.delete_if{|e| e.name == name} # Subset properties override
        properties << Property.new(name, type, options[:default])
      end
      
      # Returns all properties defined on this class
      def properties
        if @properties.nil?
          @properties = Set.new
          @properties.merge(superclass.properties) unless self == base_class
          @properties
        else
          @properties
        end
      end
      
      # Returns a hash of property name to types
      def property_types
        @properties_type ||= properties.inject({}) do |types, property|
          types[property.name] = property.type
          types
        end
      end
      
      # Returns an array of property names
      def property_names
        @property_names ||= properties.map { |property| property.name }
      end
      
      # Resets all the cached information about properties, which will cause them to be reloaded on 
      # the next request.
      def reset_property_information
        generated_methods.each { |name| undef_method(name) }
        @property_names = @properties = @property_types = @generated_methods = @inheritance_column = nil
      end
      
      # True if this isn't a concrete subclass needing a inheritence type condition.
      def descends_from_couch_foo?
        if superclass.abstract_class?
          superclass.descends_from_couch_foo?
        else
          superclass == Base
        end
      end
      
      # Sets an order which all queries to this model will be sorted by unless overriden in the finder
      # This is useful for setting a created_at sort field by default so results are automatically
      # sorted in the order they were added to the database.  NOTE - this sorts after the results
      # are returned so will not give expected behaviour when using limits or find(:first), find(:last)
      # For example,
      # class User < CouchFoo::Base
      #   property :name, String
      #   property :created_at, DateTime
      #   default_sort :created_at
      # end
      def default_sort(property)
        @default_sort_order = property
      end
      
      def default_sort_order
        @default_sort_order
      end

      # Create a view and return the documents associated with that view.  It requires a name, 
      # find_function and optional reduce function (see http://wiki.apache.org/couchdb/HTTP_view_API).
      # At the moment this function assumes you're going to emit a doc as the value (required to rebuild
      # the model after running the query)
      #
      # For example:
      #   class Note
      #     view :latest_submissions, "function(doc) {if(doc.ruby_class == 'Note') {emit([doc.created_at , doc.note], doc); } }", nil, :descending => true
      #   ...
      #   end
      #
      # This example would be an effective way to get the latest notes sorted by create date and note
      # contents.  The above view could then be called:
      # Note.latest_submissions(:limit => 5)
      # 
      # NOTE: We use descending => true and not order as order is applied after the results are retrieved 
      # from CouchDB whereas descending is a CouchDB view option.  More on this can be found in the #find
      # documentation
      # NOTE: Custom views do not worked with named scopes, any desired scopes should be coded
      # into the map function
      def view(name, map_function, reduce_function = nil, standard_options = {})
        views << View.new(name, map_function, reduce_function, standard_options)
      end

      def views
        @views ||= Set.new()
      end
      
      def view_names
        @view_names ||= views.map{ |view| view.name }
      end

      def inspect
        if self == Base
          super
        elsif abstract_class?
          "#{super}(abstract)"
        else
          attr_list = properties.map { |p| "#{p.name}: #{p.type || 'JSON'}" } * ', '
          "#{super}(#{attr_list})"
        end
      end
      
      # Log and benchmark multiple statements in a single block. Example:
      #
      #   Project.benchmark("Creating project") do
      #     project = Project.create("name" => "stuff")
      #     project.create_manager("name" => "David")
      #     project.milestones << Milestone.find(:all)
      #   end
      #
      # The benchmark is only recorded if the current level of the logger is less than or equal 
      # to the <tt>log_level</tt>, which makes it easy to include benchmarking statements in 
      # production software that will remain inexpensive because the benchmark will only be 
      # conducted if the log level is low enough.
      #
      # The logging of the multiple statements is turned off unless <tt>use_silence</tt> is set 
      # to false.
      def benchmark(title, log_level = Logger::DEBUG, use_silence = true)
        if logger && logger.level <= log_level
          result = nil
          seconds = Benchmark.realtime { result = use_silence ? silence { yield } : yield }
          logger.add(log_level, "#{title} (#{'%.5f' % seconds})")
          result
        else
          yield
        end
      end

      # Silences the logger for the duration of the block.
      def silence
        old_logger_level, logger.level = logger.level, Logger::ERROR if logger
        yield
      ensure
        logger.level = old_logger_level if logger
      end
      
      # Overwrite the default class equality method to provide support for association proxies.
      def ===(object)
        object.is_a?(self)
      end
      
      # Returns the base subclass that this class descends from. If A
      # extends CouchFoo::Base, A.base_class will return A. If B descends from A
      # through some arbitrarily deep hierarchy, B.base_class will return A.
      def base_class
        class_of_active_record_descendant(self)
      end
            
      # Set this to true if this is an abstract class (see <tt>abstract_class?</tt>).
      attr_accessor :abstract_class

      # Returns whether this class is a base CouchFoo class.  If A is a base class and
      # B descends from A, then B.base_class will return B.
      def abstract_class?
        defined?(@abstract_class) && @abstract_class == true
      end
      
      def respond_to?(method_id, include_private = false)
        if match = matches_dynamic_finder?(method_id) || matches_dynamic_finder_with_initialize_or_create?(method_id)
          return true if all_attributes_exists?(extract_attribute_names_from_match(match))
        end
        super
      end
      
      # Returns a unique UUID even across multiple machines
      def get_uuid
        @uuid ||= UUID.new
        @uuid.generate
      end
      
      private
      def find_initial(options)
        options.update(:limit => 1)
        find_every(options).first
      end

      def find_last(options)
        options.update(:descending => true, :limit => 1)
        find_every(options).first
      end 

      def find_every(options)
        options = (scope(:find) || {}).merge(options)
        find_view(options)
      end    

      def find_from_ids(ids, options)
        expects_array = ids.first.kind_of?(Array)
        return ids.first if expects_array && ids.first.empty?

        ids = ids.flatten.compact.uniq

        case ids.size
          when 0
            raise DocumentNotFound, "Couldn't find #{name} without an ID"
          when 1
            result = find_one_by_id(ids.first, options)
            expects_array ? [ result ] : result
          else
            if (database.version > 0.8)
              conditions = options[:conditions] || {}
              find_view(conditions.merge(:keys => ids))
            else
              ids.map {|id| find_one_by_id(id, options) rescue nil}.compact
            end
        end
      end
      
      # Find by document id.  Only accepts the options :conditions and :readonly.
      def find_one_by_id(id, options)
        result = instantiate(database.get(id))
        # TODO This is bad, but more efficient in DB terms
        conditions = (scope(:find) || {}).merge(options[:conditions] || {})
        ({:ruby_class => document_class_name}.merge(conditions)).each do |key, value|
          raise DocumentNotFound unless result.read_attribute(key) == value
        end
        result.readonly! if options[:readonly]
        result
      end
      
      # Finder methods must instantiate through this method to get the finder callbacks
      def instantiate(document)
        object =
            if subclass_name = document[inheritance_column]
              # No type given.
              if subclass_name.blank?
                allocate
              else
                begin
                  compute_type(subclass_name).allocate
                rescue NameError
                  raise SubclassNotFound,
                    "The inheritance mechanism failed to locate the subclass: '#{document[inheritance_column]}'. " +
                    "This error is raised because the column '#{inheritance_column}' is reserved for storing the class in case of inheritance. " +
                    "Please rename this column if you didn't intend it to be used for storing the inheritance class " +
                    "or overwrite #{self.to_s}.inheritance_column to use another column for that information."
                end
              end
            else
              allocate
            end

        object.instance_variable_set("@attributes", check_document_attributes(document))
        object.instance_variable_set("@attributes_cache", Hash.new)
        object
      end
      
      # Checks that the document only contains types that are listed as properties
      def check_document_attributes(record)
        # Add new properties
        (property_names.map{|p| p.to_s} - record.keys).each {|k| record[k] = nil}

        # Remove old properties
        record.reject!{|key, value| !(unchangeable_property_names + property_names).include?(key.to_sym)}
        record
      end
      
      # Enables dynamic finders like find_by_user_name(user_name) and 
      # find_by_user_name_and_password(user_name, password) that are turned into 
      # find(:first, :conditions => ["user_name = ?", user_name]) and  
      # find(:first, :conditions => ["user_name = ? AND password = ?", user_name, password])
      # respectively. Also works for find(:all) by using find_all_by_amount(50) that is turned into 
      # find(:all, :conditions => ["amount = ?", 50]).
      #
      # It's even possible to use all the additional parameters to find. For example, the full interface 
      # for find_all_by_amount is actually find_all_by_amount(amount, options).
      #
      # This also enables you to initialize a record if it is not found, such as 
      # find_or_initialize_by_amount(amount) or find_or_create_by_user_and_password(user, password).
      #
      # Each dynamic finder or initializer/creator is also defined in the class after it is first invoked, 
      # so that future attempts to use it do not run through method_missing.
      def method_missing(method_id, *arguments)
        if (view_names.include?(method_id))
          view = views.select{|v| v.name == method_id }.first
          generic_view(method_id.to_s, view.map_function, view.reduce_function, view.options.merge(arguments.first || {}))
        elsif match = matches_dynamic_finder?(method_id)
          finder = determine_finder(match)

          attribute_names = extract_attribute_names_from_match(match)
          super unless all_attributes_exists?(attribute_names)

          self.class_eval %{
            def self.#{method_id}(*args)
              options = args.extract_options!
              attributes = construct_attributes_from_arguments([:#{attribute_names.join(',:')}], args)
              finder_options = { :conditions => attributes }
              validate_find_options(options)
              set_readonly_option!(options)

              ActiveSupport::Deprecation.silence { send(:#{finder}, options.merge(finder_options)) }
            end
          }, __FILE__, __LINE__
          send(method_id, *arguments)
        elsif match = matches_dynamic_finder_with_initialize_or_create?(method_id)
          instantiator = determine_instantiator(match)
          attribute_names = extract_attribute_names_from_match(match)
          super unless all_attributes_exists?(attribute_names)

          self.class_eval %{
            def self.#{method_id}(*args)
              guard_protected_attributes = false

              if args[0].is_a?(Hash)
                guard_protected_attributes = true
                attributes = args[0].with_indifferent_access
                find_attributes = attributes.slice(*[:#{attribute_names.join(',:')}])
              else
                find_attributes = attributes = construct_attributes_from_arguments([:#{attribute_names.join(',:')}], args)
              end

              options = { :conditions => find_attributes }

              record = find_initial(options)

              if record.nil?
                record = self.new { |r| r.send(:attributes=, attributes, guard_protected_attributes) }
                record
              else
                record
              end
            end
          }, __FILE__, __LINE__
          send(method_id, *arguments)
        else
          super
        end
      end
      
      def matches_dynamic_finder?(method_id)
        /^find_(all_by|by)_([_a-zA-Z]\w*)$/.match(method_id.to_s)
      end

      def matches_dynamic_finder_with_initialize_or_create?(method_id)
        /^find_or_(initialize|create)_by_([_a-zA-Z]\w*)$/.match(method_id.to_s)
      end
      
      def determine_finder(match)
        match.captures.first == 'all_by' ? :find_every : :find_initial
      end

      def determine_instantiator(match)
        match.captures.first == 'initialize' ? :new : :create
      end

      def extract_attribute_names_from_match(match)
        match.captures.last.split('_and_')
      end

      def construct_attributes_from_arguments(attribute_names, arguments)
        attributes = {}
        attribute_names.each_with_index { |name, idx| attributes[name] = arguments[idx] }
        attributes
      end

      # Similar in purpose to +expand_hash_conditions_for_aggregates+.
      def expand_attribute_names_for_aggregates(attribute_names)
        expanded_attribute_names = []
        attribute_names.each do |attribute_name|
          unless (aggregation = reflect_on_aggregation(attribute_name.to_sym)).nil?
            aggregate_mapping(aggregation).each do |field_attr, aggregate_attr|
              expanded_attribute_names << field_attr
            end
          else
            expanded_attribute_names << attribute_name
          end
        end
        expanded_attribute_names
      end

      def all_attributes_exists?(attribute_names)
        attribute_names = expand_attribute_names_for_aggregates(attribute_names)
        attribute_names.all? { |name| property_names.include?(name.to_sym) }
      end
      
      # Defines an "attribute" method (like +inheritance_property+ or +document_name+). A new (class) 
      # method will be created with the given name. If a value is specified, the new method will
      # return that value (as a string). Otherwise, the given block will be used to compute the 
      # value of the method.
      #
      # The original method will be aliased, with the new name being prefixed with "original_". 
      # This allows the new method to access the original value.
      #
      # Example:
      #
      #   class A < CouchFoo::Base
      #     define_attr_method :primary_key, "sysid"
      #     define_attr_method( :inheritance_property ) do
      #       original_inheritance_property + "_id"
      #     end
      #   end
      def define_attr_method(name, value=nil, &block)
        sing = class << self; self; end
        sing.send :alias_method, "original_#{name}", name
        if block_given?
          sing.send :define_method, name, &block
        else
          # use eval instead of a block to work around a memory leak in dev
          # mode in fcgi
          sing.class_eval "def #{name}; #{value.to_s.inspect}; end"
        end
      end

      protected
      # Scope parameters to method calls within the block.  Takes a hash of method_name => parameters hash.
      # method_name may be <tt>:find</tt> or <tt>:create</tt>. <tt>:find</tt> parameters may include the <tt>:conditions</tt>,
      # <tt>:limit</tt>, and <tt>:readonly</tt> options. <tt>:create</tt> parameters are an attributes hash.
      #
      #   class Article < CouchFoo::Base
      #     def self.create_with_scope
      #       with_scope(:find => { :conditions => {:blog_id => 1} }, :create => { :blog_id => 1 }) do
      #         find(1) # => SELECT * from articles WHERE blog_id = 1 AND id = 1
      #         a = create(1)
      #         a.blog_id # => 1
      #       end
      #     end
      #   end
      #
      # In nested scopings, all previous parameters are overwritten by the innermost rule, with the exception of
      # <tt>:conditions</tt> option in <tt>:find</tt>, which is merged.
      #
      #   class Article < CouchFoo::Base
      #     def self.find_with_scope
      #       with_scope(:find => { :conditions => {:blog_id => 1}, :limit => 1 }, :create => { :blog_id => 1 }) do
      #         with_scope(:find => { :limit => 10 })
      #           find(:all) # => SELECT * from articles WHERE blog_id = 1 LIMIT 10
      #         end
      #         with_scope(:find => { :conditions => "author_id = 3" })
      #           find(:all) # => SELECT * from articles WHERE blog_id = 1 AND author_id = 3 LIMIT 1
      #         end
      #       end
      #     end
      #   end
      #
      # You can ignore any previous scopings by using the <tt>with_exclusive_scope</tt> method.
      #
      #   class Article < CouchFoo::Base
      #     def self.find_with_exclusive_scope
      #       with_scope(:find => { :conditions => {:blog_id => 1}, :limit => 1 }) do
      #         with_exclusive_scope(:find => { :limit => 10 })
      #           find(:all) # => SELECT * from articles LIMIT 10
      #         end
      #       end
      #     end
      #   end
      def with_scope(method_scoping = {}, action = :merge, &block)
        method_scoping = method_scoping.method_scoping if method_scoping.respond_to?(:method_scoping)

        # Dup first and second level of hash (method and params).
        method_scoping = method_scoping.inject({}) do |hash, (method, params)|
          hash[method] = (params == true) ? params : params.dup
          hash
        end

        method_scoping.assert_valid_keys([ :find, :create ])

        if f = method_scoping[:find]
          f.assert_valid_keys(VALID_FIND_OPTIONS)
          set_readonly_option! f
        end

        # Merge scopings
        if action == :merge && current_scoped_methods
          method_scoping = current_scoped_methods.inject(method_scoping) do |hash, (method, params)|
            case hash[method]
              when Hash
                if method == :find
                  (hash[method].keys + params.keys).uniq.each do |key|
                    merge = hash[method][key] && params[key] # merge if both scopes have the same key
                    if key == :conditions && merge
                      hash[method][key] = params[key].merge(hash[method][key])
                    else
                      hash[method][key] = hash[method][key] || params[key]
                    end
                  end
                else
                  hash[method] = params.merge(hash[method])
                end
              else
                hash[method] = params
            end
            hash
          end
        end

        self.scoped_methods << method_scoping

        begin
          yield
        ensure
          self.scoped_methods.pop
        end
      end
      
      # Works like with_scope, but discards any nested properties.
      def with_exclusive_scope(method_scoping = {}, &block)
        with_scope(method_scoping, :overwrite, &block)
      end
      
      # Test whether the given method and optional key are scoped.
      def scoped?(method, key = nil) #:nodoc:
        if current_scoped_methods && (scope = current_scoped_methods[method])
          !key || scope.has_key?(key)
        end
      end

      # Retrieve the scope for the given method and optional key.
      def scope(method, key = nil) #:nodoc:
        if current_scoped_methods && (scope = current_scoped_methods[method])
          key ? scope[key] : scope
        end
      end

      def scoped_methods #:nodoc:
        @scoped_methods ||= []
      end
      
      def current_scoped_methods #:nodoc:
        scoped_methods.last
      end
      
      # Returns the class type of the record using the current module as a prefix. So descendents of
      # MyApp::Business::Account would appear as MyApp::Business::AccountSubclass.
      def compute_type(type_name)
        modularized_name = (/^::/ =~ type_name) ? type_name : "#{parent.name}::#{type_name}"
        begin
          class_eval(modularized_name, __FILE__, __LINE__)
        rescue NameError
          class_eval(type_name, __FILE__, __LINE__)
        end
      end
      
      # Returns the class descending directly from Active Record in the inheritance hierarchy.
      def class_of_active_record_descendant(klass)
        if klass.superclass == Base || klass.superclass.abstract_class?
          klass
        elsif klass.superclass.nil?
          raise ActiveRecordError, "#{name} doesn't belong in a hierarchy descending from ActiveRecord"
        else
          class_of_active_record_descendant(klass.superclass)
        end
      end
      
      VALID_FIND_OPTIONS = [ :conditions, :include, :limit, :count, :order, :readonly, :offset, :use_key,
        :view_type, :startkey, :endkey, :return_json, :descending, :group, :group_level, 
        :include_docs, :skip, :startkey_docid, :endkey_docid, :keys]

      def validate_find_options(options) #:nodoc:
        options.assert_valid_keys(VALID_FIND_OPTIONS)
      end
      
      def set_readonly_option!(options) #:nodoc:
        # Inherit :readonly from finder scope if set
        unless options.has_key?(:readonly)
          if scoped_readonly = scope(:find, :readonly)
            options[:readonly] = scoped_readonly
          end
        end
      end
    end # ClassMethods
    
    public
    # New objects can be instantiated as either empty (pass no construction parameter) or pre-set with
    # attributes but not yet saved (pass a hash with key names matching the associated property names).
    # In both instances, valid attribute keys are determined by the property names of the model --
    # hence you can't have attributes that aren't part of the model.
    def initialize(attributes = nil)
      @attributes = attributes_from_property_definitions
      @attributes_cache = {}
      @new_record = true
      ensure_proper_type
      self.attributes = attributes
      self.class.send(:scope, :create).each { |att,value| self.send("#{att}=", value) } if self.class.send(:scoped?, :create)
      result = yield self if block_given?
      callback(:after_initialize) if respond_to_without_attributes?(:after_initialize)
      result
    end
  
    # Returns the unqiue id of the document
    def _id
      attributes["_id"]
    end
    alias :id :_id
  
    # Returns the revision id of the document
    def _rev
      attributes["_rev"]
    end
    alias :rev :_rev
    
    # Returns the ruby_class of the document, as stored in the document to know which ruby object
    # to map back to
    def ruby_class
      attributes["ruby_class"]
    end
    
    # Enables Couch Foo objects to be used as URL parameters in Action Pack automatically.
    def to_param
      (id = self.id) ? id.to_s : nil
    end
  
    # Returns true if this object hasn't been saved yet -- that is, a record for the object doesn't exist yet.
    def new_record?
      defined?(@new_record) && @new_record
    end

    # * No record exists: Creates a new record with values matching those of the object attributes.
    # * A record does exist: Updates the record with values matching those of the object attributes.
    #
    # Note: If your model specifies any validations then the method declaration dynamically
    # changes to:
    #   save(perform_validation=true, bulk_save = self.class.database.bulk_save?)
    # Calling save(false) saves the model without running validations.
    # See CouchFoo::Validations for more information.
    def save
      create_or_update
    end

    # Attempts to save the record, but instead of just returning false if it couldn't happen, it 
    # raises a DocumentNotSaved exception.
    def save!
      create_or_update || raise(DocumentNotSaved)
    end
  
    def destroy
      unless new_record?
        self.class.database.delete(@attributes)
      end
      freeze
    end
    
    def clone
      attrs = clone_attributes(:read_attribute_before_type_cast)
      attributes_protected_by_default.each {|a| attrs.delete(a) unless a == "ruby_class"}
      record = self.class.new
      record.send :instance_variable_set, '@attributes', attrs
      record
    end
    
    # Returns an instance of the specified +klass+ with the attributes of the current record. This 
    # is mostly useful in relation to inheritance structures where you want a subclass to appear as 
    # the superclass. This can be used along with record identification in Action Pack 
    # to allow, say, <tt>Client < Company</tt> to do something like render 
    # <tt>:partial => @client.becomes(Company)</tt> to render that instance using the 
    # companies/company partial instead of clients/client.
    #
    # Note: The new instance will share a link to the same attributes as the original class. So any 
    # change to the attributes in either instance will affect the other.
    def becomes(klass)
      returning klass.new do |became|
        became.instance_variable_set("@attributes", @attributes)
        became.instance_variable_set("@attributes_cache", @attributes_cache)
        became.instance_variable_set("@new_record", new_record?)
      end
    end
    
    # Updates a single attribute and saves the record. This is especially useful for boolean flags 
    # on existing records.
    # Note: This method is overwritten by the Validation module that'll make sure that updates made 
    # with this method aren't subjected to validation checks. Hence, attributes can be updated even 
    # if the full object isn't valid.
    def update_attribute(name, value)
      send(name.to_s + '=', value)
      save
    end

    # Updates all the attributes from the passed-in Hash and saves the record. If the object is 
    # invalid, the saving will fail and false will be returned.
    def update_attributes(attributes)
      self.attributes = attributes
      save
    end

    # Updates an object just like Base.update_attributes but calls save! instead of save so an 
    # exception is raised if the record is invalid.
    def update_attributes!(attributes)
      self.attributes = attributes
      save!
    end
    
    # Initializes +attribute+ to zero if +nil+ and adds the value passed as +by+ (default is 1).
    # The increment is performed directly on the underlying attribute, no setter is invoked.
    # Only makes sense for number-based attributes. Returns +self+.
    def increment(attribute, by = 1)
      self[attribute] ||= 0
      self[attribute] += by
      self
    end

    # Wrapper around +increment+ that saves the record. This method differs from
    # its non-bang version in that it passes through the attribute setter.
    # Saving is not subjected to validation checks. Returns +true+ if the
    # record could be saved.
    def increment!(attribute, by = 1)
      increment(attribute, by).update_attribute(attribute, self[attribute])
    end

    # Initializes +attribute+ to zero if +nil+ and subtracts the value passed as +by+ (default is 1).
    # The decrement is performed directly on the underlying attribute, no setter is invoked.
    # Only makes sense for number-based attributes. Returns +self+.
    def decrement(attribute, by = 1)
      self[attribute] ||= 0
      self[attribute] -= by
      self
    end

    # Wrapper around +decrement+ that saves the record. This method differs from
    # its non-bang version in that it passes through the attribute setter.
    # Saving is not subjected to validation checks. Returns +true+ if the
    # record could be saved.
    def decrement!(attribute, by = 1)
      decrement(attribute, by).update_attribute(attribute, self[attribute])
    end

    # Assigns to +attribute+ the boolean opposite of <tt>attribute?</tt>. So
    # if the predicate returns +true+ the attribute will become +false+. This
    # method toggles directly the underlying value without calling any setter.
    # Returns +self+.
    def toggle(attribute)
      self[attribute] = !send("#{attribute}?")
      self
    end

    # Wrapper around +toggle+ that saves the record. This method differs from
    # its non-bang version in that it passes through the attribute setter.
    # Saving is not subjected to validation checks. Returns +true+ if the
    # record could be saved.
    def toggle!(attribute)
      toggle(attribute).update_attribute(attribute, self[attribute])
    end
    
    # Reloads the attributes of this object from the database. The optional options argument is 
    # passed to find when reloading so you may do e.g. record.reload(:lock => true) to reload the 
    # same record with an exclusive row lock.
    def reload(options = nil)
      #clear_aggregation_cache
      clear_association_cache
      @attributes.update(self.class.find(self.id, options).instance_variable_get('@attributes'))
      @attributes_cache = {}
      self
    end
    
    # Returns the value of the attribute identified by <tt>attr_name</tt> after it has been typecast 
    # (for example, "2004-12-12" in a data property is cast to a date object, 
    # like Date.new(2004, 12, 12)).
    # (Alias for the protected read_attribute method).
    def [](attr_name)
      read_attribute(attr_name)
    end

    # Updates the attribute identified by <tt>attr_name</tt> with the specified +value+.
    # (Alias for the protected write_attribute method).
    def []=(attr_name, value)
      write_attribute(attr_name, value)
    end
  
    # Allows you to set all the attributes at once by passing in a hash with keys matching the 
    # attribute names (which again matches the property names). Sensitive attributes can be protected
    # from this form of mass-assignment by using the +attr_protected+ macro. Or you can alternatively
    # specify which attributes *can* be accessed with the +attr_accessible+ macro. Then all the
    # attributes not included in that won't be allowed to be mass-assigned.
    def attributes=(new_attributes, guard_protected_attributes = true)
      return if new_attributes.nil?
      attributes = normalize_attrs(new_attributes)

      multi_parameter_attributes = []
      attributes = remove_attributes_protected_from_mass_assignment(attributes) if guard_protected_attributes

      attributes.each do |k, v|
        k.include?("(") ? multi_parameter_attributes << [ k, v ] : send(k + "=", v)
      end

      assign_multiparameter_attributes(multi_parameter_attributes)
    end
    
    # Returns a hash of all the attributes with their names as keys and the values of the 
    # attributes as values.
    def attributes
      self.attribute_names.inject({}) do |attrs, name|
        attrs[name] = read_attribute(name)
        attrs
      end
    end
    
    # Returns a hash of attributes before typecasting and deserialization.
    def attributes_before_type_cast
      self.attribute_names.inject({}) do |attrs, name|
        attrs[name] = read_attribute_before_type_cast(name)
        attrs
      end
    end

    # Format attributes nicely for inspect.
    def attribute_for_inspect(attr_name)
      value = read_attribute(attr_name)

      if value.is_a?(String) && value.length > 50
        "#{value[0..50]}...".inspect
      elsif value.is_a?(Date) || value.is_a?(Time)
        %("#{value.to_s(:db)}")
      else
        value.inspect
      end
    end

    # Returns true if the specified +attribute+ has been set by the user or by a database load and is neither
    # nil nor empty? (the latter only applies to objects that respond to empty?, most notably Strings).
    def attribute_present?(attribute)
      value = read_attribute(attribute)
      !value.blank?
    end

    # Returns true if the given attribute is in the attributes hash
    def has_attribute?(attr_name)
      @attributes.has_key?(attr_name.to_s)
    end

    # Returns an array of names for the attributes available on this object sorted alphabetically.
    def attribute_names
      @attributes.keys.map{|a| a.to_s}.sort
    end
    
    # Returns true if the +comparison_object+ is the same object, or is of the same type and has the same id.
    def ==(comparison_object)
      comparison_object.equal?(self) ||
        (comparison_object.instance_of?(self.class) &&
          comparison_object.id == id &&
          !comparison_object.new_record?)
    end

    # Delegates to ==
    def eql?(comparison_object)
      self == (comparison_object)
    end

    # Delegates to id in order to allow two records of the same type and id to work with something like:
    #   [ Person.find(1), Person.find(2), Person.find(3) ] & [ Person.find(1), Person.find(4) ] # => [ Person.find(1) ]
    def hash
      id.hash
    end

    # Freeze the attributes hash such that associations are still accessible, even on destroyed records.
    def freeze
      @attributes.freeze; self
    end

    # Returns +true+ if the attributes hash has been frozen.
    def frozen?
      @attributes.frozen?
    end

    # Returns +true+ if the record is read only. Records loaded through joins with piggy-back
    # attributes will be marked as read only since they cannot be saved.
    def readonly?
      defined?(@readonly) && @readonly == true
    end

    # Marks this record as read only.
    def readonly!
      @readonly = true
    end

    # Returns the contents of the record as a nicely formatted string.
    def inspect
      attributes_as_nice_string = (self.class.property_names + unchangeable_property_names).collect { |name|
        "#{name}: #{attribute_for_inspect(name)}"
      }.compact.join(", ")
      "#<#{self.class} #{attributes_as_nice_string}>"
    end

    private
    def create_or_update
      raise ReadOnlyRecord if readonly?
      result = new_record? ? create : update
      result != false
    end
    
    def update
      begin
        response = self.class.database.save(attributes_before_type_cast)
        @attributes["_rev"] = response['rev']
        1
      rescue Exception => e
        logger.error "Unable to update document: #{e.message}"
        false
      end
    end
    
    def create
      @attributes["_id"] = self.class.get_uuid
      begin
        response = self.class.database.save(attributes_before_type_cast.reject{|key,value| key == "_rev"})
        @attributes["_rev"] = response['rev']
        @new_record = false
        @attributes["_id"]
      rescue Exception => e
        @attributes["_id"] = nil
        logger.error "Unable to create document: #{e.message}"
        false
      end
    end
    
    # Sets the attribute used for inheritance to this class name if this is not the CouchFoo::Base 
    # descendent.  Considering the hierarchy Reply < Message < ActiveRecord::Base, this makes it 
    # possible to do Reply.new without having to set <tt>Reply[Reply.inheritance_column] = "Reply"</tt>
    # yourself. No such attribute would be set for objects of the Message class in that example.
    def ensure_proper_type
      unless self.class.descends_from_couch_foo?
        write_attribute(self.class.inheritance_column, self.class.name)
      end
    end

    def normalize_attrs(new_attributes)
      attributes = new_attributes.dup
      attributes.stringify_keys!
      id = attributes.delete("id")
      rev = attributes.delete("rev")
      attributes["_id"] = id if id
      attributes["_rev"] = rev if rev
      attributes
    end
    
    def remove_attributes_protected_from_mass_assignment(attributes)
      safe_attributes =
        if self.class.accessible_attributes.nil? && self.class.protected_attributes.nil?
          attributes.reject { |key, value| attributes_protected_by_default.include?(key.gsub(/\(.+/, "")) }
        elsif self.class.protected_attributes.nil?
          attributes.reject { |key, value| !self.class.accessible_attributes.include?(key.gsub(/\(.+/, "")) || attributes_protected_by_default.include?(key.gsub(/\(.+/, "")) }
        elsif self.class.accessible_attributes.nil?
          attributes.reject { |key, value| self.class.protected_attributes.include?(key.gsub(/\(.+/,"")) || attributes_protected_by_default.include?(key.gsub(/\(.+/, "")) }
        else
          raise "Declare either attr_protected or attr_accessible for #{self.class}, but not both."
        end

      removed_attributes = attributes.keys - safe_attributes.keys

      if removed_attributes.any?
        logger.debug "WARNING: Can't mass-assign these protected attributes: #{removed_attributes.join(', ')}"
      end

      safe_attributes
    end
    
    def attributes_protected_by_default
      attributes = @@unchangeable_property_names + [self.class.inheritance_column]
      attributes.map{|p| p.to_s}
    end
    
    def attributes_from_property_definitions
      attribs = {}
      attribs["_id"] = nil
      attribs["_rev"] = nil
      attribs["ruby_class"] = self.class.document_class_name
      self.class.properties.inject(attribs) do |attributes, property|
        attributes[property.name.to_s] = convert_to_json(property.default, property.type)
        attributes
      end
    end
    
    # Instantiates objects for all attribute classes that needs more than one constructor parameter. 
    # This is done by calling new on the property type or aggregation type (through composed_of) 
    # object with these parameters.  So having the pairs written_on(1) = "2004", 
    # written_on(2) = "6", written_on(3) = "24", will instantiate written_on (a date type) with 
    # Date.new("2004", "6", "24"). You can also specify a typecast character in the parentheses to 
    # have the parameters typecasted before they're used in the constructor. Use i for Fixnum, 
    # f for Float, s for String, and a for Array. If all the values for a given attribute are empty,
    # the attribute will be set to nil.
    def assign_multiparameter_attributes(pairs)
      execute_callstack_for_multiparameter_attributes(
        extract_callstack_for_multiparameter_attributes(pairs)
      )
    end
    
    def instantiate_time_object(name, values)
      Time.time_with_datetime_fallback(@@default_timezone, *values)
    end
    
    def execute_callstack_for_multiparameter_attributes(callstack)
      errors = []
      callstack.each do |name, values|
        klass = type_for_property(name)
        if values.empty?
          send(name + "=", nil)
        else
          begin
            value = if klass == Time
              instantiate_time_object(name, values)
            elsif klass == Date
              begin
                Date.new(*values)
              rescue ArgumentError => ex # if Date.new raises an exception on an invalid date
                instantiate_time_object(name, values).to_date # we instantiate Time object and convert it back to a date thus using Time's logic in handling invalid dates
              end
            else
              klass.new(*values)
            end

            send(name + "=", value)
          rescue => ex
            errors << AttributeAssignmentError.new("error on assignment #{values.inspect} to #{name}", ex, name)
          end
        end
      end
      unless errors.empty?
        raise MultiparameterAssignmentErrors.new(errors), "#{errors.size} error(s) on assignment of multiparameter attributes"
      end
    end

    def extract_callstack_for_multiparameter_attributes(pairs)
      attributes = { }

      for pair in pairs
        multiparameter_name, value = pair
        attribute_name = multiparameter_name.split("(").first
        attributes[attribute_name] = [] unless attributes.include?(attribute_name)

        unless value.empty?
          attributes[attribute_name] <<
            [ find_parameter_position(multiparameter_name), type_cast_attribute_value(multiparameter_name, value) ]
        end
      end

      attributes.each { |name, values| attributes[name] = values.sort_by{ |v| v.first }.collect { |v| v.last } }
    end
    
    def type_cast_attribute_value(multiparameter_name, value)
      multiparameter_name =~ /\([0-9]*([a-z])\)/ ? value.send("to_" + $1) : value
    end

    def find_parameter_position(multiparameter_name)
      multiparameter_name.scan(/\(([0-9]*).*\)/).first.first
    end

    def clone_attributes(reader_method = :read_attribute, attributes = {})
      self.attribute_names.inject(attributes) do |attrs, name|
        attrs[name] = clone_attribute_value(reader_method, name)
        attrs
      end
    end

    def clone_attribute_value(reader_method, attribute_name)
      value = send(reader_method, attribute_name)
      value.duplicable? ? value.clone : value
    rescue TypeError, NoMethodError
      value
    end
      
    def type_for_property(name)
      self.class.property_types[name.to_sym]
    end
  end
end
