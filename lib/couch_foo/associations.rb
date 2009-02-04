require 'couch_foo/associations/association_proxy'
require 'couch_foo/associations/association_collection'
require 'couch_foo/associations/belongs_to_association'
require 'couch_foo/associations/belongs_to_polymorphic_association'
require 'couch_foo/associations/has_one_association'
require 'couch_foo/associations/has_many_association'
#require 'couch_foo/associations/has_many_through_association'
require 'couch_foo/associations/has_and_belongs_to_many_association'
#require 'couch_foo/associations/has_one_through_association'

module CouchFoo
  class HasManyThroughAssociationNotFoundError < CouchFooError #:nodoc:
    def initialize(owner_class_name, reflection)
      super("Could not find the association #{reflection.options[:through].inspect} in model #{owner_class_name}")
    end
  end

  class HasManyThroughAssociationPolymorphicError < CouchFooError #:nodoc:
    def initialize(owner_class_name, reflection, source_reflection)
      super("Cannot have a has_many :through association '#{owner_class_name}##{reflection.name}' on the polymorphic object '#{source_reflection.class_name}##{source_reflection.name}'.")
    end
  end

  class HasManyThroughAssociationPointlessSourceTypeError < CouchFooError #:nodoc:
    def initialize(owner_class_name, reflection, source_reflection)
      super("Cannot have a has_many :through association '#{owner_class_name}##{reflection.name}' with a :source_type option if the '#{reflection.through_reflection.class_name}##{source_reflection.name}' is not polymorphic.  Try removing :source_type on your association.")
    end
  end

  class HasManyThroughSourceAssociationNotFoundError < CouchFooError #:nodoc:
    def initialize(reflection)
      through_reflection      = reflection.through_reflection
      source_reflection_names = reflection.source_reflection_names
      source_associations     = reflection.through_reflection.klass.reflect_on_all_associations.collect { |a| a.name.inspect }
      super("Could not find the source association(s) #{source_reflection_names.collect(&:inspect).to_sentence :connector => 'or'} in model #{through_reflection.klass}.  Try 'has_many #{reflection.name.inspect}, :through => #{through_reflection.name.inspect}, :source => <name>'.  Is it one of #{source_associations.to_sentence :connector => 'or'}?")
    end
  end

  class HasManyThroughSourceAssociationMacroError < CouchFooError #:nodoc:
    def initialize(reflection)
      through_reflection = reflection.through_reflection
      source_reflection  = reflection.source_reflection
      super("Invalid source reflection macro :#{source_reflection.macro}#{" :through" if source_reflection.options[:through]} for has_many #{reflection.name.inspect}, :through => #{through_reflection.name.inspect}.  Use :source to specify the source reflection.")
    end
  end

  class HasManyThroughCantAssociateThroughHasManyReflection < CouchFooError #:nodoc:
    def initialize(owner, reflection)
      super("Cannot modify association '#{owner.class.name}##{reflection.name}' because the source reflection class '#{reflection.source_reflection.class_name}' is associated to '#{reflection.through_reflection.class_name}' via :#{reflection.source_reflection.macro}.")
    end
  end
  class HasManyThroughCantAssociateNewRecords < CouchFooError #:nodoc:
    def initialize(owner, reflection)
      super("Cannot associate new records through '#{owner.class.name}##{reflection.name}' on '#{reflection.source_reflection.class_name rescue nil}##{reflection.source_reflection.name rescue nil}'. Both records must have an id in order to create the has_many :through record associating them.")
    end
  end

  class HasManyThroughCantDissociateNewRecords < CouchFooError #:nodoc:
    def initialize(owner, reflection)
      super("Cannot dissociate new records through '#{owner.class.name}##{reflection.name}' on '#{reflection.source_reflection.class_name rescue nil}##{reflection.source_reflection.name rescue nil}'. Both records must have an id in order to delete the has_many :through record associating them.")
    end
  end

  class EagerLoadPolymorphicError < CouchFooError #:nodoc:
    def initialize(reflection)
      super("Can not eagerly load the polymorphic association #{reflection.name.inspect}")
    end
  end

  class ReadOnlyAssociation < CouchFooError #:nodoc:
    def initialize(reflection)
      super("Can not add to a has_many :through association.  Try adding to #{reflection.through_reflection.name.inspect}.")
    end
  end

  module Associations # :nodoc:
    def self.included(base)
      base.extend(ClassMethods)
    end

    # Clears out the association cache
    def clear_association_cache #:nodoc:
      self.class.reflect_on_all_associations.to_a.each do |assoc|
        instance_variable_set "@#{assoc.name}", nil
      end unless self.new_record?
    end

    # Associations are a set of macro-like class methods for tying objects together through foreign keys. They express relationships like
    # "Project has one Project Manager" or "Project belongs to a Portfolio". Each macro adds a number of methods to the class which are
    # specialized according to the collection or association symbol and the options hash. It works much the same way as Ruby's own <tt>attr*</tt>
    # methods. Example:
    #
    #   class Project < CouchFoo::Base
    #     belongs_to              :portfolio
    #     has_one                 :project_manager
    #     has_many                :milestones
    #     has_and_belongs_to_many :categories
    #   end
    #
    # The project class now has the following methods (and more) to ease the traversal and manipulation of its relationships:
    # * <tt>Project#portfolio, Project#portfolio=(portfolio), Project#portfolio.nil?</tt>
    # * <tt>Project#project_manager, Project#project_manager=(project_manager), Project#project_manager.nil?,</tt>
    # * <tt>Project#milestones.empty?, Project#milestones.size, Project#milestones, Project#milestones<<(milestone),</tt>
    #   <tt>Project#milestones.delete(milestone), Project#milestones.find(milestone_id), Project#milestones.find(:all, options),</tt>
    #   <tt>Project#milestones.build, Project#milestones.create</tt>
    # * <tt>Project#categories.empty?, Project#categories.size, Project#categories, Project#categories<<(category1),</tt>
    #   <tt>Project#categories.delete(category1)</tt>
    #
    # === Note
    #
    # The current CouchFoo implementation does not include has_and_belongs_to_many  This will be added 
    # in a future release along with an option for using has_many in an inline context, so all the
    # associated documents are stored in the parent itself rather than in separate records.
    #
    # === A word of warning
    #
    # Don't create associations that have the same name as instance methods of CouchFoo::Base. Since the association
    # adds a method with that name to its model, it will override the inherited method and break things.
    # For instance, +attributes+ and +connection+ would be bad choices for association names.
    #
    # == Auto-generated methods
    #
    # === Singular associations (one-to-one)
    #                                     |            |  belongs_to  |
    #   generated methods                 | belongs_to | :polymorphic | has_one
    #   ----------------------------------+------------+--------------+---------
    #   #other                            |     X      |      X       |    X
    #   #other=(other)                    |     X      |      X       |    X
    #   #build_other(attributes={})       |     X      |              |    X
    #   #create_other(attributes={})      |     X      |              |    X
    #   #other.create!(attributes={})     |            |              |    X
    #   #other.nil?                       |     X      |      X       |
    #
    # ===Collection associations (one-to-many / many-to-many)
    #                                     |       |          | has_many
    #   generated methods                 | habtm | has_many | :through
    #   ----------------------------------+-------+----------+----------
    #   #others                           |   X   |    X     |    X
    #   #others=(other,other,...)         |   X   |    X     |    X
    #   #other_ids                        |   X   |    X     |    X
    #   #other_ids=(id,id,...)            |   X   |    X     |    X
    #   #others<<                         |   X   |    X     |    X
    #   #others.push                      |   X   |    X     |    X
    #   #others.concat                    |   X   |    X     |    X
    #   #others.build(attributes={})      |   X   |    X     |    X
    #   #others.create(attributes={})     |   X   |    X     |    X
    #   #others.create!(attributes={})    |   X   |    X     |    X
    #   #others.size                      |   X   |    X     |    X
    #   #others.length                    |   X   |    X     |    X
    #   #others.count                     |   X   |    X     |    X
    #   #others.sum(args*,&block)         |   X   |    X     |    X
    #   #others.empty?                    |   X   |    X     |    X
    #   #others.clear                     |   X   |    X     |    X
    #   #others.delete(other,other,...)   |   X   |    X     |    X
    #   #others.delete_all                |   X   |    X     |
    #   #others.destroy_all               |   X   |    X     |    X
    #   #others.find(*args)               |   X   |    X     |    X
    #   #others.find_first                |   X   |          |
    #   #others.uniq                      |   X   |    X     |    X
    #   #others.reset                     |   X   |    X     |    X
    #
    # == Cardinality and associations
    #
    # Couch Foo associations can be used to describe one-to-one, one-to-many and many-to-many
    # relationships between models. Each model uses an association to describe its role in
    # the relation. The +belongs_to+ association is always used in the model that has
    # the foreign key.
    #
    # === One-to-one
    #
    # Use +has_one+ in the base, and +belongs_to+ in the associated model.
    #
    #   class Employee < CouchFoo::Base
    #     has_one :office
    #   end
    #   class Office < CouchFoo::Base
    #     belongs_to :employee    # foreign key - employee_id
    #   end
    #
    # === One-to-many
    #
    # Use +has_many+ in the base, and +belongs_to+ in the associated model.
    #
    #   class Manager < CouchFoo::Base
    #     has_many :employees
    #   end
    #   class Employee < CouchFoo::Base
    #     belongs_to :manager     # foreign key - manager_id
    #   end
    #
    # === Many-to-many
    #
    # Not implement yet
    #
    # == Is it a +belongs_to+ or +has_one+ association?
    #
    # Both express a 1-1 relationship. The difference is mostly where to place the foreign key, which goes on the model for the class
    # declaring the +belongs_to+ relationship. Example:
    #
    #   class User < CouchFoo::Base
    #     # I reference an account.
    #     belongs_to :account
    #   end
    #
    #   class Account < CouchFoo::Base
    #     # One user references me.
    #     has_one :user
    #   end
    #
    # The properties definitions for these classes could look something like:
    #   class User < CouchFoo::Base
    #     property :account_id, Integer
    #     property :name, String
    #   end
    #
    #   class Account < CouchFoo::Base
    #     property :name, String
    #   end
    #
    # == Unsaved objects and associations
    #
    # You can manipulate objects and associations before they are saved to the database, but there is some special behavior you should be
    # aware of, mostly involving the saving of associated objects.
    #
    # === One-to-one associations
    #
    # * Assigning an object to a +has_one+ association automatically saves that object and the object being replaced (if there is one), in
    #   order to update their primary keys - except if the parent object is unsaved (<tt>new_record? == true</tt>).
    # * If either of these saves fail (due to one of the objects being invalid) the assignment statement returns +false+ and the assignment
    #   is cancelled.
    # * If you wish to assign an object to a +has_one+ association without saving it, use the <tt>association.build</tt> method (documented below).
    # * Assigning an object to a +belongs_to+ association does not save the object, since the foreign key field belongs on the parent. It
    #   does not save the parent either.
    #
    # === Collections
    #
    # * Adding an object to a collection (+has_many+ or +has_and_belongs_to_many+) automatically saves that object, except if the parent object
    #   (the owner of the collection) is not yet stored in the database.
    # * If saving any of the objects being added to a collection (via <tt>push</tt> or similar) fails, then <tt>push</tt> returns +false+.
    # * You can add an object to a collection without automatically saving it by using the <tt>collection.build</tt> method (documented below).
    # * All unsaved (<tt>new_record? == true</tt>) members of the collection are automatically saved when the parent is saved.
    #
    # === Association callbacks
    #
    # Similar to the normal callbacks that hook into the lifecycle of an Couch Foo object, you can also define callbacks that get
    # triggered when you add an object to or remove an object from an association collection. Example:
    #
    #   class Project
    #     has_and_belongs_to_many :developers, :after_add => :evaluate_velocity
    #
    #     def evaluate_velocity(developer)
    #       ...
    #     end
    #   end
    #
    # It's possible to stack callbacks by passing them as an array. Example:
    #
    #   class Project
    #     has_and_belongs_to_many :developers, :after_add => [:evaluate_velocity, Proc.new { |p, d| p.shipping_date = Time.now}]
    #   end
    #
    # Possible callbacks are: +before_add+, +after_add+, +before_remove+ and +after_remove+.
    #
    # Should any of the +before_add+ callbacks throw an exception, the object does not get added to the collection. Same with
    # the +before_remove+ callbacks; if an exception is thrown the object doesn't get removed.
    #
    # === Association extensions
    #
    # The proxy objects that control the access to associations can be extended through anonymous modules. This is especially
    # beneficial for adding new finders, creators, and other factory-type methods that are only used as part of this association.
    # Example:
    #
    #   class Account < CouchFoo::Base
    #     has_many :people do
    #       def find_or_create_by_name(name)
    #         first_name, last_name = name.split(" ", 2)
    #         find_or_create_by_first_name_and_last_name(first_name, last_name)
    #       end
    #     end
    #   end
    #
    #   person = Account.find(:first).people.find_or_create_by_name("David Heinemeier Hansson")
    #   person.first_name # => "David"
    #   person.last_name  # => "Heinemeier Hansson"
    #
    # If you need to share the same extensions between many associations, you can use a named extension module. Example:
    #
    #   module FindOrCreateByNameExtension
    #     def find_or_create_by_name(name)
    #       first_name, last_name = name.split(" ", 2)
    #       find_or_create_by_first_name_and_last_name(first_name, last_name)
    #     end
    #   end
    #
    #   class Account < CouchFoo::Base
    #     has_many :people, :extend => FindOrCreateByNameExtension
    #   end
    #
    #   class Company < CouchFoo::Base
    #     has_many :people, :extend => FindOrCreateByNameExtension
    #   end
    #
    # If you need to use multiple named extension modules, you can specify an array of modules with the <tt>:extend</tt> option.
    # In the case of name conflicts between methods in the modules, methods in modules later in the array supercede
    # those earlier in the array. Example:
    #
    #   class Account < CouchFoo::Base
    #     has_many :people, :extend => [FindOrCreateByNameExtension, FindRecentExtension]
    #   end
    #
    # Some extensions can only be made to work with knowledge of the association proxy's internals.
    # Extensions can access relevant state using accessors on the association proxy:
    #
    # * +proxy_owner+ - Returns the object the association is part of.
    # * +proxy_reflection+ - Returns the reflection object that describes the association.
    # * +proxy_target+ - Returns the associated object for +belongs_to+ and +has_one+, or the collection of associated objects for +has_many+ and +has_and_belongs_to_many+.
    #
    # === Association Join Models
    #
    # This is not supported yet
    #
    # === Polymorphic Associations
    #
    # Polymorphic associations on models are not restricted on what types of models they can be associated with.  Rather, they
    # specify an interface that a +has_many+ association must adhere to.
    #
    #   class Asset < CouchFoo::Base
    #     belongs_to :attachable, :polymorphic => true
    #   end
    #
    #   class Post < CouchFoo::Base
    #     has_many :assets, :as => :attachable         # The :as option specifies the polymorphic interface to use.
    #   end
    #
    #   @asset.attachable = @post
    #
    # This works by using a type property in addition to a foreign key to specify the associated record.  In the Asset example, you'd need
    # an +attachable_id+ key attribute and an +attachable_type+ string attribute.
    #
    # Using polymorphic associations in combination with inheritance is a little tricky. In order
    # for the associations to work as expected, ensure that you store the base model in the
    # type property of the polymorphic association. To continue with the asset example above, suppose 
    # there are guest posts and member posts that use inheritence. In this case, there must be a +type+ 
    # property in the Post model.
    #
    #   class Asset < CouchFoo::Base
    #     belongs_to :attachable, :polymorphic => true
    #
    #     def attachable_type=(sType)
    #        super(sType.to_s.classify.constantize.class.to_s)
    #     end
    #   end
    #
    #   class Post < CouchFoo::Base
    #     # because we store "Post" in attachable_type now :dependent => :destroy will work
    #     has_many :assets, :as => :attachable, :dependent => :destroy
    #   end
    #
    #   class GuestPost < Post
    #   end
    #
    #   class MemberPost < Post
    #   end
    #
    # == Caching
    #
    # All of the methods are built on a simple caching principle that will keep the result of the last query around unless specifically
    # instructed not to. The cache is even shared across methods to make it even cheaper to use the macro-added methods without
    # worrying too much about performance at the first go. Example:
    #
    #   project.milestones             # fetches milestones from the database
    #   project.milestones.size        # uses the milestone cache
    #   project.milestones.empty?      # uses the milestone cache
    #   project.milestones(true).size  # fetches milestones from the database
    #   project.milestones             # uses the milestone cache
    #
    # == Eager loading of associations
    #
    # Not implemented yet
    #
    # == Modules
    #
    # By default, associations will look for objects within the current module scope. Consider:
    #
    #   module MyApplication
    #     module Business
    #       class Firm < CouchFoo::Base
    #          has_many :clients
    #        end
    #
    #       class Company < CouchFoo::Base; end
    #     end
    #   end
    #
    # When Firm#clients is called, it will in turn call <tt>MyApplication::Business::Company.find(firm.id)</tt>. If you want to associate
    # with a class in another module scope, this can be done by specifying the complete class name.  Example:
    #
    #   module MyApplication
    #     module Business
    #       class Firm < CouchFoo::Base; end
    #     end
    #
    #     module Billing
    #       class Account < CouchFoo::Base
    #         belongs_to :firm, :class_name => "MyApplication::Business::Firm"
    #       end
    #     end
    #   end
    #
    # == Type safety with <tt>CouchFoo::AssociationTypeMismatch</tt>
    #
    # If you attempt to assign an object to an association that doesn't match the inferred or specified <tt>:class_name</tt>, you'll
    # get an <tt>CouchFoo::AssociationTypeMismatch</tt>.
    #
    # == Options
    #
    # All of the association macros can be specialized through options. This makes cases more complex than the simple and guessable ones
    # possible.
    module ClassMethods
      # Adds the following methods for retrieval and query of collections of associated objects:
      # +collection+ is replaced with the symbol passed as the first argument, so
      # <tt>has_many :clients</tt> would add among others <tt>clients.empty?</tt>.
      # * <tt>collection(force_reload = false)</tt> - Returns an array of all the associated objects.
      #   An empty array is returned if none are found.
      # * <tt>collection<<(object, ...)</tt> - Adds one or more objects to the collection by setting their foreign keys to the collection's primary key.
      # * <tt>collection.delete(object, ...)</tt> - Removes one or more objects from the collection by setting their foreign keys to +NULL+.
      #   This will also destroy the objects if they're declared as +belongs_to+ and dependent on this model.
      # * <tt>collection=objects</tt> - Replaces the collections content by deleting and adding objects as appropriate.
      # * <tt>collection_singular_ids</tt> - Returns an array of the associated objects' ids
      # * <tt>collection_singular_ids=ids</tt> - Replace the collection with the objects identified by the primary keys in +ids+
      # * <tt>collection.clear</tt> - Removes every object from the collection. This destroys the associated objects if they
      #   are associated with <tt>:dependent => :destroy</tt>, deletes them directly from the database if <tt>:dependent => :delete_all</tt>,
      #   otherwise sets their foreign keys to +NULL+.
      # * <tt>collection.empty?</tt> - Returns +true+ if there are no associated objects.
      # * <tt>collection.size</tt> - Returns the number of associated objects.
      # * <tt>collection.find</tt> - Finds an associated object according to the same rules as Base.find.
      # * <tt>collection.build(attributes = {}, ...)</tt> - Returns one or more new objects of the collection type that have been instantiated
      #   with +attributes+ and linked to this object through a foreign key, but have not yet been saved. *Note:* This only works if an
      #   associated object already exists, not if it's +nil+!
      # * <tt>collection.create(attributes = {})</tt> - Returns a new object of the collection type that has been instantiated
      #   with +attributes+, linked to this object through a foreign key, and that has already been saved (if it passed the validation).
      #   *Note:* This only works if an associated object already exists, not if it's +nil+!
      #
      # Example: A Firm class declares <tt>has_many :clients</tt>, which will add:
      # * <tt>Firm#clients</tt> (similar to <tt>Clients.find :all, :conditions => "firm_id = #{id}"</tt>)
      # * <tt>Firm#clients<<</tt>
      # * <tt>Firm#clients.delete</tt>
      # * <tt>Firm#clients=</tt>
      # * <tt>Firm#client_ids</tt>
      # * <tt>Firm#client_ids=</tt>
      # * <tt>Firm#clients.clear</tt>
      # * <tt>Firm#clients.empty?</tt> (similar to <tt>firm.clients.size == 0</tt>)
      # * <tt>Firm#clients.size</tt> (similar to <tt>Client.count "firm_id = #{id}"</tt>)
      # * <tt>Firm#clients.find</tt> (similar to <tt>Client.find(id, :conditions => "firm_id = #{id}")</tt>)
      # * <tt>Firm#clients.build</tt> (similar to <tt>Client.new("firm_id" => id)</tt>)
      # * <tt>Firm#clients.create</tt> (similar to <tt>c = Client.new("firm_id" => id); c.save; c</tt>)
      # The declaration can also include an options hash to specialize the behavior of the association.
      #
      # Options are:
      # * <tt>:class_name</tt> - Specify the class name of the association. Use it only if that name can't be inferred
      #   from the association name. So <tt>has_many :products</tt> will by default be linked to the Product class, but
      #   if the real class name is SpecialProduct, you'll have to specify it with this option.
      # * <tt>:conditions</tt> - Specify the conditions that the associated objects must meet in order to be included
      #   in the results.  For example <tt>has_many :posts, :conditions => {:published => true}</tt>.  This will also
      #   create published posts with <tt>@blog.posts.create</tt> or <tt>@blog.posts.build</tt>.
      # * <tt>:order</tt> - Specify the order in which the associated objects are returned by a property to sort on,
      #   for example :order => :product_weight.  See notes in CouchFoo#find when using with :limit
      # * <tt>:dependent</tt> - If set to <tt>:destroy</tt> all the associated objects are destroyed
      #   alongside this object by calling their +destroy+ method.  If set to <tt>:delete_all</tt> all associated
      #   objects are deleted *without* calling their +destroy+ method.  If set to <tt>:nullify</tt> all associated
      #   objects' foreign keys are set to +NULL+ *without* calling their +save+ callbacks. *Warning:* This option is ignored when also using
      #   the <tt>:through</tt> option.
      # * <tt>:extend</tt> - Specify a named module for extending the proxy. See "Association extensions".
      # * <tt>:include</tt> - Specify second-order associations that should be eager loaded when the collection is loaded.
      # * <tt>:limit</tt> - An integer determining the limit on the number of rows that should be returned.  See notes
      #   in CouchFoo#find when using with :order
      # * <tt>:offset</tt> - An integer determining the offset from where the rows should be fetched. So at 5, it would skip the first 4 rows.
      # * <tt>:as</tt> - Specifies a polymorphic interface (See <tt>belongs_to</tt>).
      # * <tt>:through</tt> - Not implemented at the moment
      # * <tt>:source_type</tt> - Specifies type of the source association used by <tt>has_many :through</tt> queries where the source
      #   association is a polymorphic +belongs_to+.
      # * <tt>:uniq</tt> - If true, duplicates will be omitted from the collection. Useful in conjunction with <tt>:through</tt>.
      # * <tt>:readonly</tt> - If true, all the associated objects are readonly through the association.
      # * <tt>:validate</tt> - If false, don't validate the associated objects when saving the parent object. true by default.
      #
      # Option examples:
      #   has_many :comments, :order => :posted_on
      #   has_many :comments, :include => :author
      #   has_many :people, :class_name => "Person", :conditions => {deleted => 0}, :order => "name"
      #   has_many :tracks, :order => :position, :dependent => :destroy
      #   has_many :comments, :dependent => :nullify
      #   has_many :tags, :as => :taggable
      #   has_many :reports, :readonly => true
      def has_many(association_id, options = {}, &extension)
        reflection = create_has_many_reflection(association_id, options, &extension)
        configure_dependency_for_has_many(reflection)

        add_multiple_associated_validation_callbacks(reflection.name) unless options[:validate] == false
        add_multiple_associated_save_callbacks(reflection.name)
        add_association_callbacks(reflection.name, reflection.options)

        #if options[:through]
        #  collection_accessor_methods(reflection, HasManyThroughAssociation)
        #else
          collection_accessor_methods(reflection, HasManyAssociation)
        #end
      end

      # Adds the following methods for retrieval and query of a single associated object:
      # +association+ is replaced with the symbol passed as the first argument, so
      # <tt>has_one :manager</tt> would add among others <tt>manager.nil?</tt>.
      # * <tt>association(force_reload = false)</tt> - Returns the associated object. +nil+ is returned if none is found.
      # * <tt>association=(associate)</tt> - Assigns the associate object, extracts the primary key, sets it as the foreign key,
      #   and saves the associate object.
      # * <tt>association.nil?</tt> - Returns +true+ if there is no associated object.
      # * <tt>build_association(attributes = {})</tt> - Returns a new object of the associated type that has been instantiated
      #   with +attributes+ and linked to this object through a foreign key, but has not yet been saved. Note: This ONLY works if
      #   an association already exists. It will NOT work if the association is +nil+.
      # * <tt>create_association(attributes = {})</tt> - Returns a new object of the associated type that has been instantiated
      #   with +attributes+, linked to this object through a foreign key, and that has already been saved (if it passed the validation).
      #
      # Example: An Account class declares <tt>has_one :beneficiary</tt>, which will add:
      # * <tt>Account#beneficiary</tt> (similar to <tt>Beneficiary.find(:first, :conditions => "account_id = #{id}")</tt>)
      # * <tt>Account#beneficiary=(beneficiary)</tt> (similar to <tt>beneficiary.account_id = account.id; beneficiary.save</tt>)
      # * <tt>Account#beneficiary.nil?</tt>
      # * <tt>Account#build_beneficiary</tt> (similar to <tt>Beneficiary.new("account_id" => id)</tt>)
      # * <tt>Account#create_beneficiary</tt> (similar to <tt>b = Beneficiary.new("account_id" => id); b.save; b</tt>)
      #
      # The declaration can also include an options hash to specialize the behavior of the association.
      #
      # Options are:
      # * <tt>:class_name</tt> - Specify the class name of the association. Use it only if that name can't be inferred
      #   from the association name. So <tt>has_one :manager</tt> will by default be linked to the Manager class, but
      #   if the real class name is Person, you'll have to specify it with this option.
      # * <tt>:conditions</tt> - Specify the conditions that the associated objects must meet in order to be included
      #   in the results.  For example <tt>has_many :posts, :conditions => {:published => true}</tt>.  This will also
      #   create published posts with <tt>@blog.posts.create</tt> or <tt>@blog.posts.build</tt>.
      # * <tt>:order</tt> - Specify the order in which the associated objects are returned by a property to sort on,
      #   for example :order => :product_weight.  See notes in CouchFoo#find when using with :limit
      # * <tt>:dependent</tt> - If set to <tt>:destroy</tt>, the associated object is destroyed when this object is. If set to
      #   <tt>:delete</tt>, the associated object is deleted *without* calling its destroy method. If set to <tt>:nullify</tt>, the associated
      #   object's foreign key is set to +NULL+. Also, association is assigned.
      # * <tt>:foreign_key</tt> - Specify the foreign key used for the association. By default this is guessed to be the name
      #   of this class in lower-case and "_id" suffixed. So a Person class that makes a +has_one+ association will use "person_id"
      #   as the default <tt>:foreign_key</tt>.
      # * <tt>:include</tt> - Specify second-order associations that should be eager loaded when this object is loaded.
      # * <tt>:as</tt> - Specifies a polymorphic interface (See <tt>belongs_to</tt>).
      # * <tt>:through</tt> - Not implemented yet
      # * <tt>:source</tt> - Not implemented yet
      # * <tt>:source_type</tt> - Not implemented yet
      # * <tt>:readonly</tt> - If true, the associated object is readonly through the association.
      # * <tt>:validate</tt> - If false, don't validate the associated object when saving the parent object. +false+ by default.
      #
      # Option examples:
      #   has_one :credit_card, :dependent => :destroy  # destroys the associated credit card
      #   has_one :credit_card, :dependent => :nullify  # updates the associated records foreign key value to NULL rather than destroying it
      #   has_one :last_comment, :class_name => "Comment", :order => :posted_on
      #   has_one :project_manager, :class_name => "Person", :conditions => "role = 'project_manager'"
      #   has_one :attachment, :as => :attachable
      #   has_one :boss, :readonly => :true
      def has_one(association_id, options = {})
        #if options[:through]
        #  reflection = create_has_one_through_reflection(association_id, options)
        #  association_accessor_methods(reflection, CouchFoo::Associations::HasOneThroughAssociation)
        #else
          reflection = create_has_one_reflection(association_id, options)

          ivar = "@#{reflection.name}"

          method_name = "has_one_after_save_for_#{reflection.name}".to_sym
          define_method(method_name) do
            association = instance_variable_get("#{ivar}") if instance_variable_defined?("#{ivar}")

            if !association.nil? && (new_record? || association.new_record? || association["#{reflection.primary_key_name}"] != id)
              association["#{reflection.primary_key_name}"] = id
              association.save(true)
            end
          end
          after_save method_name

          add_single_associated_validation_callbacks(reflection.name) if options[:validate] == true
          association_accessor_methods(reflection, HasOneAssociation)
          association_constructor_method(:build,  reflection, HasOneAssociation)
          association_constructor_method(:create, reflection, HasOneAssociation)

          configure_dependency_for_has_one(reflection)
        #end
      end

      # Adds the following methods for retrieval and query for a single associated object for which this object holds an id:
      # +association+ is replaced with the symbol passed as the first argument, so
      # <tt>belongs_to :author</tt> would add among others <tt>author.nil?</tt>.
      # * <tt>association(force_reload = false)</tt> - Returns the associated object. +nil+ is returned if none is found.
      # * <tt>association=(associate)</tt> - Assigns the associate object, extracts the primary key, and sets it as the foreign key.
      # * <tt>association.nil?</tt> - Returns +true+ if there is no associated object.
      # * <tt>build_association(attributes = {})</tt> - Returns a new object of the associated type that has been instantiated
      #   with +attributes+ and linked to this object through a foreign key, but has not yet been saved.
      # * <tt>create_association(attributes = {})</tt> - Returns a new object of the associated type that has been instantiated
      #   with +attributes+, linked to this object through a foreign key, and that has already been saved (if it passed the validation).
      #
      # Example: A Post class declares <tt>belongs_to :author</tt>, which will add:
      # * <tt>Post#author</tt> (similar to <tt>Author.find(author_id)</tt>)
      # * <tt>Post#author=(author)</tt> (similar to <tt>post.author_id = author.id</tt>)
      # * <tt>Post#author?</tt> (similar to <tt>post.author == some_author</tt>)
      # * <tt>Post#author.nil?</tt>
      # * <tt>Post#build_author</tt> (similar to <tt>post.author = Author.new</tt>)
      # * <tt>Post#create_author</tt> (similar to <tt>post.author = Author.new; post.author.save; post.author</tt>)
      # The declaration can also include an options hash to specialize the behavior of the association.
      #
      # Options are:
      # * <tt>:class_name</tt> - Specify the class name of the association. Use it only if that name can't be inferred
      #   from the association name. So <tt>has_one :author</tt> will by default be linked to the Author class, but
      #   if the real class name is Person, you'll have to specify it with this option.
      # * <tt>:conditions</tt> - Specify the conditions that the associated objects must meet in order to be included
      #   in the results.  For example <tt>has_many :posts, :conditions => {:published => true}</tt>.  This will also
      #   create published posts with <tt>@blog.posts.create</tt> or <tt>@blog.posts.build</tt>.
      # * <tt>:foreign_key</tt> - Specify the foreign key used for the association. By default this is guessed to be the name
      #   of the association with an "_id" suffix. So a class that defines a <tt>belongs_to :person</tt> association will use
      #   "person_id" as the default <tt>:foreign_key</tt>. Similarly, <tt>belongs_to :favorite_person, :class_name => "Person"</tt>
      #   will use a foreign key of "favorite_person_id".
      # * <tt>:dependent</tt> - If set to <tt>:destroy</tt>, the associated object is destroyed when this object is. If set to
      #   <tt>:delete</tt>, the associated object is deleted *without* calling its destroy method. This option should not be specified when
      #   <tt>belongs_to</tt> is used in conjunction with a <tt>has_many</tt> relationship on another class because of the potential to leave
      #   orphaned records behind.
      # * <tt>:counter_cache</tt> - Caches the number of belonging objects on the associate class through the use of +increment_counter+
      #   and +decrement_counter+. The counter cache is incremented when an object of this class is created and decremented when it's
      #   destroyed. This requires that a property named <tt>#{document_name}_count</tt> (such as +comments_count+ for a belonging Comment class)
      #   is used on the associate class (such as a Post class). You can also specify a custom counter cache property by providing
      #   a property name instead of a +true+/+false+ value to this option (e.g., <tt>:counter_cache => :my_custom_counter</tt>.)
      #   When creating a counter cache property, the database statement or migration must specify a default value of <tt>0</tt>, failing to do 
      #   this results in a counter with +NULL+ value, which will never increment.
      #   Note: Specifying a counter cache will add it to that model's list of readonly attributes using +attr_readonly+.
      # * <tt>:include</tt> - Specify second-order associations that should be eager loaded when this object is loaded.
      # * <tt>:polymorphic</tt> - Specify this association is a polymorphic association by passing +true+.
      #   Note: If you've enabled the counter cache, then you may want to add the counter cache attribute
      #   to the +attr_readonly+ list in the associated classes (e.g. <tt>class Post; attr_readonly :comments_count; end</tt>).
      # * <tt>:readonly</tt> - If true, the associated object is readonly through the association.
      # * <tt>:validate</tt> - If false, don't validate the associated objects when saving the parent object. +false+ by default.
      #
      # Option examples:
      #   belongs_to :firm, :foreign_key => "client_of"
      #   belongs_to :author, :class_name => "Person", :foreign_key => "author_id"
      #   belongs_to :valid_coupon, :class_name => "Coupon", :foreign_key => "coupon_id",
      #              :conditions => {discounts = #{payments_count}}
      #   belongs_to :attachable, :polymorphic => true
      #   belongs_to :project, :readonly => true
      #   belongs_to :post, :counter_cache => true
      def belongs_to(association_id, options = {})
        reflection = create_belongs_to_reflection(association_id, options)

        ivar = "@#{reflection.name}"

        if reflection.options[:polymorphic]
          association_accessor_methods(reflection, BelongsToPolymorphicAssociation)

          method_name = "polymorphic_belongs_to_before_save_for_#{reflection.name}".to_sym
          define_method(method_name) do
            association = instance_variable_get("#{ivar}") if instance_variable_defined?("#{ivar}")

            if association && association.target
              if association.new_record?
                association.save(true)
              end

              if association.updated?
                self["#{reflection.primary_key_name}"] = association.id
                self["#{reflection.options[:foreign_type]}"] = association.class.name.to_s
              end
            end
          end
          before_save method_name
        else
          association_accessor_methods(reflection, BelongsToAssociation)
          association_constructor_method(:build,  reflection, BelongsToAssociation)
          association_constructor_method(:create, reflection, BelongsToAssociation)

          method_name = "belongs_to_before_save_for_#{reflection.name}".to_sym
          define_method(method_name) do
            association = instance_variable_get("#{ivar}") if instance_variable_defined?("#{ivar}")

            if !association.nil?
              if association.new_record?
                association.save(true)
              end

              if association.updated?
                self["#{reflection.primary_key_name}"] = association.id
              end
            end
          end
          before_save method_name
        end

        # Create the callbacks to update counter cache
        if options[:counter_cache]
          cache_property = options[:counter_cache] == true ?
            "#{self.to_s.demodulize.underscore.pluralize}_count" :
            options[:counter_cache]

          method_name = "belongs_to_counter_cache_after_create_for_#{reflection.name}".to_sym
          define_method(method_name) do
            association = send("#{reflection.name}")
            association.class.increment_counter("#{cache_property}", send("#{reflection.primary_key_name}")) unless association.nil?
          end
          after_create method_name

          method_name = "belongs_to_counter_cache_before_destroy_for_#{reflection.name}".to_sym
          define_method(method_name) do
            association = send("#{reflection.name}")
            association.class.decrement_counter("#{cache_property}", send("#{reflection.primary_key_name}")) unless association.nil?
          end
          before_destroy method_name

          module_eval(
            "#{reflection.class_name}.send(:attr_readonly,\"#{cache_property}\".intern) if defined?(#{reflection.class_name}) && #{reflection.class_name}.respond_to?(:attr_readonly)"
          )
        end

        add_single_associated_validation_callbacks(reflection.name) if options[:validate] == true

        configure_dependency_for_belongs_to(reflection)
      end

      
#      def has_and_belongs_to_many(association_id, options = {}, &extension)
#        reflection = create_has_and_belongs_to_many_reflection(association_id, options, &extension)
#
#        add_multiple_associated_validation_callbacks(reflection.name) unless options[:validate] == false
#        add_multiple_associated_save_callbacks(reflection.name)
#        collection_accessor_methods(reflection, HasAndBelongsToManyAssociation)
#
#        # Don't use a before_destroy callback since users' before_destroy
#        # callbacks will be executed after the association is wiped out.
#        old_method = "destroy_without_habtm_shim_for_#{reflection.name}"
#        class_eval <<-end_eval unless method_defined?(old_method)
#          alias_method :#{old_method}, :destroy_without_callbacks
#          def destroy_without_callbacks
#            #{reflection.name}.clear
#            #{old_method}
#          end
#        end_eval
#
#        add_association_callbacks(reflection.name, options)
#      end

      private
        def association_accessor_methods(reflection, association_proxy_class)
          ivar = "@#{reflection.name}"

          define_method(reflection.name) do |*params|
            force_reload = params.first unless params.empty?

            association = instance_variable_get(ivar) if instance_variable_defined?(ivar)

            if association.nil? || force_reload
              association = association_proxy_class.new(self, reflection)
              retval = association.reload
              if retval.nil? and association_proxy_class == BelongsToAssociation
                instance_variable_set(ivar, nil)
                return nil
              end
              instance_variable_set(ivar, association)
            end

            association.target.nil? ? nil : association
          end

          define_method("#{reflection.name}=") do |new_value|
            association = instance_variable_get(ivar) if instance_variable_defined?(ivar)

            if association.nil? || association.target != new_value
              association = association_proxy_class.new(self, reflection)
            end

#            if association_proxy_class == HasOneThroughAssociation
#              association.create_through_record(new_value)
#              self.send(reflection.name, new_value)
#            else
              association.replace(new_value)
              instance_variable_set(ivar, new_value.nil? ? nil : association)
#            end
          end

          define_method("set_#{reflection.name}_target") do |target|
            return if target.nil? and association_proxy_class == BelongsToAssociation
            association = association_proxy_class.new(self, reflection)
            association.target = target
            instance_variable_set(ivar, association)
          end
        end

        def collection_reader_method(reflection, association_proxy_class)
          define_method(reflection.name) do |*params|
            ivar = "@#{reflection.name}"

            force_reload = params.first unless params.empty?
            association = instance_variable_get(ivar) if instance_variable_defined?(ivar)

            unless association.respond_to?(:loaded?)
              association = association_proxy_class.new(self, reflection)
              instance_variable_set(ivar, association)
            end

            association.reload if force_reload

            association
          end

          define_method("#{reflection.name.to_s.singularize}_ids") do
            send(reflection.name).map(&:id)
          end
        end

        def collection_accessor_methods(reflection, association_proxy_class, writer = true)
          collection_reader_method(reflection, association_proxy_class)

          if writer
            define_method("#{reflection.name}=") do |new_value|
              # Loads proxy class instance (defined in collection_reader_method) if not already loaded
              association = send(reflection.name)
              association.replace(new_value)
              association
            end

            define_method("#{reflection.name.to_s.singularize}_ids=") do |new_value|
              ids = (new_value || []).reject { |nid| nid.blank? }
              send("#{reflection.name}=", reflection.class_name.constantize.find(ids))
            end
          end
        end
        
        def add_single_associated_validation_callbacks(association_name)
          method_name = "validate_associated_records_for_#{association_name}".to_sym
          define_method(method_name) do
            association = instance_variable_get("@#{association_name}")
            if !association.nil?
              errors.add "#{association_name}" unless association.target.nil? || association.valid?
            end
          end
        
          validate method_name
        end
        
        def add_multiple_associated_validation_callbacks(association_name)
          method_name = "validate_associated_records_for_#{association_name}".to_sym
          ivar = "@#{association_name}"

          define_method(method_name) do
            association = instance_variable_get(ivar) if instance_variable_defined?(ivar)

            if association.respond_to?(:loaded?)
              if new_record?
                association
              elsif association.loaded?
                association.select { |record| record.new_record? }
              else
                association.target.select { |record| record.new_record? }
              end.each do |record|
                errors.add "#{association_name}" unless record.valid?
              end
            end
          end

          validate method_name
        end

        def add_multiple_associated_save_callbacks(association_name)
          ivar = "@#{association_name}"

          method_name = "before_save_associated_records_for_#{association_name}".to_sym
          define_method(method_name) do
            @new_record_before_save = new_record?
            true
          end
          before_save method_name

          method_name = "after_create_or_update_associated_records_for_#{association_name}".to_sym
          define_method(method_name) do
            association = instance_variable_get("#{ivar}") if instance_variable_defined?("#{ivar}")

            records_to_save = if @new_record_before_save
              association
            elsif association.respond_to?(:loaded?) && association.loaded?
              association.select { |record| record.new_record? }
            elsif association.respond_to?(:loaded?) && !association.loaded?
              association.target.select { |record| record.new_record? }
            else
              []
            end
            records_to_save.each { |record| association.send(:insert_record, record) } unless records_to_save.blank?

            # reconstruct the conditions now that we know the owner's id
            association.send(:construct_conditions) if association.respond_to?(:construct_conditions)
          end

          # Doesn't use after_save as that would save associations added in after_create/after_update twice
          after_create method_name
          after_update method_name
        end

        def association_constructor_method(constructor, reflection, association_proxy_class)
          define_method("#{constructor}_#{reflection.name}") do |*params|
            ivar = "@#{reflection.name}"

            attributees      = params.first unless params.empty?
            replace_existing = params[1].nil? ? true : params[1]
            association      = instance_variable_get(ivar) if instance_variable_defined?(ivar)

            if association.nil?
              association = association_proxy_class.new(self, reflection)
              instance_variable_set(ivar, association)
            end

            if association_proxy_class == HasOneAssociation
              association.send(constructor, attributees, replace_existing)
            else
              association.send(constructor, attributees)
            end
          end
        end

        # See HasManyAssociation#delete_records.  Dependent associations
        # delete children, otherwise foreign key is set to NULL.
        def configure_dependency_for_has_many(reflection)
          if reflection.options.include?(:dependent)
            case reflection.options[:dependent]
              when :destroy
                method_name = "has_many_dependent_destroy_for_#{reflection.name}".to_sym
                define_method(method_name) do
                  send("#{reflection.name}").each { |o| o.destroy }
                end
                before_destroy method_name
              when :delete_all
                method_name = "has_many_dependent_delete_for_#{reflection.name}".to_sym
                define_method(method_name) do
                  send("#{reflection.name}").each { |o| o.delete }
                end
                before_destroy method_name
              when :nullify
                method_name = "has_many_dependent_nullify_for_#{reflection.name}".to_sym
                define_method(method_name) do
                  send("#{reflection.name}").each { |o| o.update_attribute({reflection.primary_key_name.to_sym => nil}, true) }
                  self.class.database.commit
                end
                before_destroy method_name
              else
                raise ArgumentError, "The :dependent option expects either :destroy, :delete_all, or :nullify (#{reflection.options[:dependent].inspect})"
            end
          end
        end

        def configure_dependency_for_has_one(reflection)
          if reflection.options.include?(:dependent)
            case reflection.options[:dependent]
              when :destroy
                method_name = "has_one_dependent_destroy_for_#{reflection.name}".to_sym
                define_method(method_name) do
                  association = send("#{reflection.name}")
                  association.destroy unless association.nil?
                end
                before_destroy method_name
              when :delete
                method_name = "has_one_dependent_delete_for_#{reflection.name}".to_sym
                define_method(method_name) do
                  association = send("#{reflection.name}")
                  association.class.delete(association.id) unless association.nil?
                end
                before_destroy method_name
              when :nullify
                method_name = "has_one_dependent_nullify_for_#{reflection.name}".to_sym
                define_method(method_name) do
                  association = send("#{reflection.name}")
                  association.update_attribute("#{reflection.primary_key_name}", nil) unless association.nil?
                end
                before_destroy method_name
              else
                raise ArgumentError, "The :dependent option expects either :destroy, :delete or :nullify (#{reflection.options[:dependent].inspect})"
            end
          end
        end

        def configure_dependency_for_belongs_to(reflection)
          if reflection.options.include?(:dependent)
            case reflection.options[:dependent]
              when :destroy
                method_name = "belongs_to_dependent_destroy_for_#{reflection.name}".to_sym
                define_method(method_name) do
                  association = send("#{reflection.name}")
                  association.destroy unless association.nil?
                end
                before_destroy method_name
              when :delete
                method_name = "belongs_to_dependent_delete_for_#{reflection.name}".to_sym
                define_method(method_name) do
                  association = send("#{reflection.name}")
                  association.class.delete(association.id) unless association.nil?
                end
                before_destroy method_name
              else
                raise ArgumentError, "The :dependent option expects either :destroy or :delete (#{reflection.options[:dependent].inspect})"
            end
          end
        end

        def create_has_many_reflection(association_id, options, &extension)
          options.assert_valid_keys(
            :class_name, :foreign_key, :dependent,
            :conditions, :include, :order, :limit, :count, :offset, :skip,
            :as, :through, :source, :source_type,
            :uniq,
            :before_add, :after_add, :before_remove, :after_remove,
            :extend, :readonly,
            :validate,
            :startkey, :endkey, :keys, :view_type, :descending, :startkey_docid, :endkey_docid
          )

          options[:extend] = create_extension_modules(association_id, extension, options[:extend])

          create_reflection(:has_many, association_id, options, self)
        end

        def create_has_one_reflection(association_id, options)
          options.assert_valid_keys(
            :class_name, :foreign_key, :remote, :conditions, :order, :include, 
            :dependent, :counter_cache, :extend, :as, :readonly, :validate
          )

          create_reflection(:has_one, association_id, options, self)
        end
        
        #def create_has_one_through_reflection(association_id, options)
        #  options.assert_valid_keys(
       #     :class_name, :foreign_key, :remote, :select, :conditions, :order, :include, :dependent, :counter_cache, :extend, :as, :through, :source, :source_type, :validate
        #  )
        #  create_reflection(:has_one, association_id, options, self)
        #end

        def create_belongs_to_reflection(association_id, options)
          options.assert_valid_keys(
            :class_name, :foreign_key, :foreign_type, :remote, :select, :conditions, 
            :include, :dependent, :counter_cache, :extend, :polymorphic, :readonly, :validate
          )

          reflection = create_reflection(:belongs_to, association_id, options, self)

          if options[:polymorphic]
            reflection.options[:foreign_type] ||= reflection.class_name.underscore + "_type"
          end

          reflection
        end

        def create_has_and_belongs_to_many_reflection(association_id, options, &extension)
          options.assert_valid_keys(
            :class_name, :foreign_key, :association_foreign_key,
            :conditions, :include, :order, :group, :offset, :skip,
            :uniq,
            :before_add, :after_add, :before_remove, :after_remove,
            :extend, :readonly,
            :validate,
            :startkey, :endkey, :keys, :view_type, :descending, :startkey_docid, :endkey_docid
          )

          options[:extend] = create_extension_modules(association_id, extension, options[:extend])

          reflection = create_reflection(:has_and_belongs_to_many, association_id, options, self)
          # TODO rename join_table when get here
          reflection.options[:join_table] ||= join_table_name(undecorated_table_name(self.to_s), undecorated_table_name(reflection.class_name))

          reflection
        end

        def reflect_on_included_associations(associations)
          [ associations ].flatten.collect { |association| reflect_on_association(association.to_s.intern) }
        end

        def guard_against_unlimitable_reflections(reflections, options)
          if (options[:offset] || options[:limit] || options[:count]) && !using_limitable_reflections?(reflections)
            raise(
              ConfigurationError,
              "You can not use offset and limit together with has_many or has_and_belongs_to_many associations"
            )
          end
        end

        def using_limitable_reflections?(reflections)
          reflections.reject { |r| [ :belongs_to, :has_one ].include?(r.macro) }.length.zero?
        end

        def add_association_callbacks(association_name, options)
          callbacks = %w(before_add after_add before_remove after_remove)
          callbacks.each do |callback_name|
            full_callback_name = "#{callback_name}_for_#{association_name}"
            defined_callbacks = options[callback_name.to_sym]
            if options.has_key?(callback_name.to_sym)
              class_inheritable_reader full_callback_name.to_sym
              write_inheritable_attribute(full_callback_name.to_sym, [defined_callbacks].flatten)
            else
              write_inheritable_attribute(full_callback_name.to_sym, [])
            end
          end
        end

        def create_extension_modules(association_id, block_extension, extensions)
          if block_extension
            extension_module_name = "#{self.to_s.demodulize}#{association_id.to_s.camelize}AssociationExtension"

            silence_warnings do
              self.parent.const_set(extension_module_name, Module.new(&block_extension))
            end
            Array(extensions).push("#{self.parent}::#{extension_module_name}".constantize)
          else
            Array(extensions)
          end
        end
    end
  end
end
