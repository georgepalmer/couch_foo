module CouchFoo
  module AttributeMethods
    DEFAULT_SUFFIXES = %w(= ? _before_type_cast)
    ATTRIBUTE_TYPES_CACHED_BY_DEFAULT = [Time, DateTime, Date]
    JSON_DATETIME_FORMAT = "%Y/%m/%d %H:%M:%S +0000"
    
    def self.included(base)
      base.extend ClassMethods
      base.attribute_method_suffix(*DEFAULT_SUFFIXES)
      base.cattr_accessor :attribute_types_cached_by_default, :instance_writer => false
      base.attribute_types_cached_by_default = ATTRIBUTE_TYPES_CACHED_BY_DEFAULT
    end
    
    module ClassMethods

      # Declares a method available for all attributes with the given suffix.
      # Uses +method_missing+ and <tt>respond_to?</tt> to rewrite the method
      #
      #   #{attr}#{suffix}(*args, &block)
      #
      # to
      #
      #   attribute#{suffix}(#{attr}, *args, &block)
      #
      # An <tt>attribute#{suffix}</tt> instance method must exist and accept at least
      # the +attr+ argument.
      #
      # For example:
      #
      #   class Person < ActiveRecord::Base
      #     attribute_method_suffix '_changed?'
      #
      #     private
      #       def attribute_changed?(attr)
      #         ...
      #       end
      #   end
      #
      #   person = Person.find(1)
      #   person.name_changed?    # => false
      #   person.name = 'Hubert'
      #   person.name_changed?    # => true
      def attribute_method_suffix(*suffixes)
        attribute_method_suffixes.concat suffixes
        rebuild_attribute_method_regexp
      end
      
      # Returns MatchData if method_name is an attribute method.
      def match_attribute_method?(method_name)
        rebuild_attribute_method_regexp unless defined?(@@attribute_method_regexp) && @@attribute_method_regexp
        @@attribute_method_regexp.match(method_name)
      end
      
      # Contains the names of the generated attribute methods.
      def generated_methods #:nodoc:
        @generated_methods ||= Set.new
      end
      
      def generated_methods?
        !generated_methods.empty?
      end
      
      # Generates accessors, mutators and query methods for registered properties
      def define_attribute_methods
        return if generated_methods?
        property_names.each do |name|
          unless instance_method_already_implemented?(name)
            define_read_method(name.to_sym)
          end
          unless instance_method_already_implemented?("#{name}=")
            define_write_method(name.to_sym)
          end
          unless instance_method_already_implemented?("#{name}?")
            define_question_method(name)
          end
        end
      end
      alias :define_read_methods :define_attribute_methods
      
      # Checks whether the method is defined in the model or any of its subclasses
      # that also derive from Couch Foo. Raises DangerousAttributeError if the
      # method is defined by Couch Foo.
      def instance_method_already_implemented?(method_name)
        method_name = method_name.to_s
        return true if method_name =~ /^id(=$|\?$|$)/
        @_defined_class_methods         ||= ancestors.first(ancestors.index(CouchFoo::Base)).sum([]) { |m| m.public_instance_methods(false) | m.private_instance_methods(false) | m.protected_instance_methods(false) }.map(&:to_s).to_set
        @@_defined_couchfoo_methods ||= (CouchFoo::Base.public_instance_methods(false) | CouchFoo::Base.private_instance_methods(false) | CouchFoo::Base.protected_instance_methods(false)).map(&:to_s).to_set
        raise DangerousAttributeError, "#{method_name} is defined by CouchFoo" if @@_defined_couchfoo_methods.include?(method_name)
        @_defined_class_methods.include?(method_name)
      end
      
      # +cache_attributes+ allows you to declare which converted attribute values should
      # be cached. Usually caching only pays off for attributes with expensive conversion
      # methods, like time related columns (e.g. +created_at+, +updated_at+).
      def cache_attributes(*attribute_names)
        attribute_names.each {|attr| cached_attributes << attr.to_s}
      end
    
      # Returns the attributes which are cached. By default time related columns
      # with datatype <tt>:datetime, :timestamp, :time, :date</tt> are cached.
      def cached_attributes
        @cached_attributes ||=
          property_types.select{|k,v| attribute_types_cached_by_default.include?(v)}.map{|e| e.first.to_s}.to_set
      end
    
      # Returns +true+ if the provided attribute is being cached.
      def cache_attribute?(attr_name)
        cached_attributes.include?(attr_name)
      end
      
      private
      # Suffixes a, ?, c become regexp /(a|\?|c)$/
      def rebuild_attribute_method_regexp
        suffixes = attribute_method_suffixes.map { |s| Regexp.escape(s) }
        @@attribute_method_regexp = /(#{suffixes.join('|')})$/.freeze
      end

      # Default to =, ?, _before_type_cast
      def attribute_method_suffixes
        @@attribute_method_suffixes ||= []
      end
      
      # Define an attribute reader method
      def define_read_method(attr_name)
        evaluate_attribute_method attr_name, "def #{attr_name}; read_attribute('#{attr_name}'); end" 
      end
      
      # Defines a predicate method <tt>attr_name?</tt>
      def define_question_method(attr_name)
        evaluate_attribute_method attr_name, "def #{attr_name}?; query_attribute('#{attr_name}'); end", "#{attr_name}?"
      end
  
      # Defines an attribute writer method
      def define_write_method(attr_name)
        evaluate_attribute_method attr_name, "def #{attr_name}=(new_value);write_attribute('#{attr_name}', new_value);end", "#{attr_name}="
      end
      
      # Evaluate the definition for an attribute related method
      def evaluate_attribute_method(attr_name, method_definition, method_name=attr_name)
        unless unchangeable_property_names.include?(attr_name.to_sym)
          generated_methods << method_name
        end

        begin
          class_eval(method_definition, __FILE__, __LINE__)
        rescue SyntaxError => err
          generated_methods.delete(attr_name)
          if logger
            logger.warn "Exception occurred during reader method compilation."
            logger.warn "Maybe #{attr_name} is not a valid Ruby identifier?"
            logger.warn "#{err.message}"
          end
        end
      end
    end # ClassMethods
      
    # Allows access to the object attributes, which are held in the <tt>@attributes</tt> hash, as 
    # though they were first-class methods. So a Person class with a name attribute can use 
    # Person#name and Person#name= and never directly use the attributes hash -- except for multiple
    # assigns with CouchFoo#attributes=. A Milestone class can also ask Milestone#completed? to
    # test that the completed attribute is not +nil+ or 0.
    #
    # It's also possible to instantiate related objects, so a Client class belonging to the clients
    # table with a +master_id+ foreign key can instantiate master through Client#master.
    def method_missing(method_id, *args, &block)
      method_name = method_id.to_s

      # Make sure methods are generated
      if !self.class.generated_methods?
        self.class.define_attribute_methods
        if self.class.generated_methods.include?(method_name)
          return self.send(method_id, *args, &block)
        end
      end

      # Unchangeable properties are called directly, not through generated methods
      if self.class.unchangeable_property_names.include?(method_id)
        send(method_id, *args, &block)
      elsif md = self.class.match_attribute_method?(method_name)
        attribute_name, method_type = md.pre_match, md.to_s
        if @attributes.include?(attribute_name)
          __send__("attribute#{method_type}", attribute_name, *args, &block)
        else
          super
        end
      elsif attributes.include?(method_name)
        read_attribute(method_name)
      else
        super
      end
    end
    
    # Returns the value of the attribute identified by <tt>attr_name</tt> after it has been typecast (for example,
    # "2004-12-12" in a data type is cast to a date object, like Date.new(2004, 12, 12)).
    def read_attribute(attr_name)
      convert_to_type(@attributes[attr_name.to_s], type_for_property(attr_name.to_sym))
    end

    def read_attribute_before_type_cast(attr_name)
      @attributes[attr_name]
    end

    # Updates the attribute identified by <tt>attr_name</tt> with the specified +value+. Empty strings for fixnum and float
    # types are turned into +nil+.
    def write_attribute(attr_name, value)
      attr_name = attr_name.to_s
      @attributes_cache.delete(attr_name)
      @attributes[attr_name] = convert_to_json(value, type_for_property(attr_name.to_sym))
    end

    def query_attribute(attr_name)
      unless value = read_attribute(attr_name)
        false
      else
        column_type = type_for_property(attr_name)
        if column_type.nil?
          if Numeric === value || value !~ /[^0-9]/
            !value.to_i.zero?
          else
            !value.blank?
          end
        elsif column_type == Integer || column_type == Float
          !value.zero?
        else
          !value.blank?
        end
      end
    end
    
    # A Person object with a name attribute can ask <tt>person.respond_to?("name")</tt>,
    # <tt>person.respond_to?("name=")</tt>, and <tt>person.respond_to?("name?")</tt>
    # which will all return +true+.
    alias :respond_to_without_attributes? :respond_to?
    def respond_to?(method, include_priv = false)
      method_name = method.to_s
      if super
        return true
      elsif !self.class.generated_methods?
        self.class.define_attribute_methods
        if self.class.generated_methods.include?(method_name)
          return true
        end
      end
        
      if @attributes.nil?
        return super
      elsif @attributes.include?(method_name)
        return true
      elsif md = self.class.match_attribute_method?(method_name)
        return true if @attributes.include?(md.pre_match)
      end
      super
    end

    protected
    def convert_to_json(value, type)
      return nil if value.nil?

      #Not keen on type hack for case statement
      case type.to_s
        when "String"
          value.to_s
        when "Integer"
          value.to_i
        when "Float"
          value.to_f
        when "DateTime"
          DateTime.parse(value.to_s).strftime(JSON_DATETIME_FORMAT)
        when "Time"
          Time.at(value.to_f).strftime(JSON_DATETIME_FORMAT)
        when "Date"
          Date.new(value.year, value.month, value.day).strftime(JSON_DATETIME_FORMAT)
        when "TrueClass"
          convert_boolean(value)
        when "Boolean"
          convert_boolean(value)
        else
          # Calling to_json on Array or Hash makes them strings = bad
          if value.is_a?(Array) || value.is_a?(Hash)
            value
          else
            value.to_json rescue value
          end
      end
    end

    # Converts a value to its type, or if not specified tries calling from_json on the value before
    # falling back on just using the value
    def convert_to_type(value, type)
      return nil if value.nil?

      #Not keen on type hack for case statement
      case type.to_s
        when "String"
          value.to_s
        when "Integer"
          value.to_i
        when "Float"
          value.to_f
        when "DateTime"
          DateTime.parse(value.to_s)
        when "Time"
          Time.at(value.to_f)
        when "Date"
          Date.new(value.year, value.month, value.day)
        when "TrueClass"
          convert_boolean(value)
        when "Boolean"
          convert_boolean(value)
        else
          type.from_json(value) rescue value
      end
    end

    private
    def convert_boolean(value)
      return false if value.nil? || value == "0" || value == 0 # Bit of a hack but keeps AR compatability
      true & value
    end
    
    def missing_attribute(attr_name, stack)
      raise ActiveRecord::MissingAttributeError, "missing attribute: #{attr_name}", stack
    end
    
    # Handle *? for method_missing.
    def attribute?(attribute_name)
      query_attribute(attribute_name)
    end

    # Handle *= for method_missing.
    def attribute=(attribute_name, value)
      write_attribute(attribute_name, value)
    end
    
    # Handle *_before_type_cast for method_missing.
    def attribute_before_type_cast(attribute_name)
      read_attribute_before_type_cast(attribute_name)
    end
  end
end
