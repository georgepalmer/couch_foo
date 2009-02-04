module CouchFoo
  module Calculations #:nodoc:
    CALCULATIONS_OPTIONS = [:conditions, :order, :distinct, :limit, :count, :offset, :include]
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Count operates using two different approaches.
      #
      # * Count all: By not passing any parameters to count, it will return a count of all the rows for the model.
      # * Count using options will find the row count matched by the options used.
      #
      # The second approach, count using options, accepts an option hash as the only parameter. The options are:
      #
      # * <tt>:conditions</tt>: A conditions hash like { :user_name => username }. See conditions in the intro.
      # * <tt>:include</tt>: Named associations that should be loaded at the same time.  See eager loading 
      #   under Associations.
      # * <tt>:order</tt>: An element to order on, eg :order => :user_name
      # * <tt>:distinct</tt>: Set this to true to remove repeating elements
      #
      # Examples for counting all:
      #   Person.count         # returns the total count of all people
      #
      # Examples for count with options:
      #   Person.count(:conditions => {age = 26})
      #
      # Note: <tt>Person.count(:all)</tt> will not work because it will use <tt>:all</tt> as the condition.  Use Person.count instead.
      def count(options = {})
        calculate(:count, nil, options)
      end

      # Calculates the average value on a given property.  The value is returned as a float.  See +calculate+ for examples with options.
      #
      #   Person.average('age')
      def average(attribute_name, options = {})
        calculate(:avg, attribute_name, options)
      end

      # Calculates the minimum value on a given property.  The value is returned with the same data type of the property.  See +calculate+ for examples with options.
      #
      #   Person.minimum('age')
      def minimum(attribute_name, options = {})
        calculate(:min, attribute_name, options)
      end

      # Calculates the maximum value on a given property.  The value is returned with the same data type of the property.  See +calculate+ for examples with options.
      #
      #   Person.maximum('age')
      def maximum(attribute_name, options = {})
        calculate(:max, attribute_name, options)
      end

      # Calculates the sum of values on a given property.  The value is returned with the same data type of the property.  See +calculate+ for examples with options.
      #
      #   Person.sum('age')
      def sum(attribute_name, options = {})
        calculate(:sum, attribute_name, options)
      end

      # This calculates aggregate values in the given property.  Methods for count, sum, average, minimum, 
      # and maximum have been added as shortcuts.
      # Options such as <tt>:conditions</tt>, <tt>:order</tt>, <tt>:count</tt> and <tt>:distinct</tt> 
      # can be passed to customize the query.
      #
      # Options:
      # * <tt>:conditions</tt>: A conditions hash like { :user_name => username }. See conditions in the intro.
      # * <tt>:include</tt>: Named associations that should be loaded at the same time.  See eager loading 
      #   under Associations.
      # * <tt>:order</tt>: An element to order on, eg :order => :user_name
      # * <tt>:distinct</tt>: Set this to true to remove repeating elements
      #
      # Examples:
      #   Person.calculate(:count, :all) # The same as Person.count
      #   Person.average(:age) # Find the average of people
      #   Person.minimum(:age, :conditions => {:last_name => 'Drake'}) # Finds the minimum age for everyone with a last name other than 'Drake'
      #   Person.sum("2 * age")
      def calculate(operation, attribute_name, options = {})
        validate_calculation_options(operation, options)
        catch :invalid_query do
          return execute_simple_calculation(operation, attribute_name, options)
        end
        0
      end

      protected
        def execute_simple_calculation(operation, attribute_name, options) #:nodoc:
          if operation == :count
            value = count_view(options)
          else
            raise "NotImplementedYet"
            #TODO test sum on associationproxy when done
          end
          type_cast_calculated_value(value, attribute_name, operation)
        end

      private
        def validate_calculation_options(operation, options = {})
          options.assert_valid_keys(CALCULATIONS_OPTIONS)
        end

        def type_cast_calculated_value(value, attribute_name, operation = nil)
          operation = operation.to_s.downcase
          case operation
            when 'count' then value.to_i
            when 'sum'   then type_cast_using_property(value || '0', attribute_name)
            when 'avg'   then value && value.to_d
            else type_cast_using_property(value, attribute_name)
          end
        end
        
        def type_cast_using_property(value, attribute_name)
          attribute_name ? convert_to_type(value, type_for_property(attribute_name.to_sym)) : value
        end
    end
  end
end
