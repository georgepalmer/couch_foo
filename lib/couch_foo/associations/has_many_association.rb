module CouchFoo
  module Associations
    class HasManyAssociation < AssociationCollection #:nodoc:
      # Count the number of associated records.
      # With CouchDB it does not make sense to have a second view for this count as it is likely
      # that at some point the developer will access the objects themselves via find and thus create
      # a suitable view.  With CouchDB > 0.8 we can use the reduce function but for earlier
      # versions we just do a find and count the results  
      def count(*args)
        options = args.extract_options!
        options[:conditions] = @association_conditions.merge(options[:conditions] || {})
        if database.version > 0.8
          value = count_view(options)
        else
          value = find(:all, options).size
        end

        limit  = @reflection.options[:limit]
        offset = @reflection.options[:offset]

        if limit || offset
          [ [value - offset.to_i, 0].max, limit.to_i ].min
        else
          value
        end
      end

      protected
        def count_records
          count = if has_cached_counter?
            @owner.send(:read_attribute, cached_counter_attribute_name)
          else
            @reflection.klass.count(:conditions => @association_conditions, :include => @reflection.options[:include])
          end

          # If there's nothing in the database and @target has no new records
          # we are certain the current target is an empty array. This is a
          # documented side-effect of the method that may avoid an extra SELECT.
          @target ||= [] and loaded if count == 0
          
          if @reflection.options[:limit]
            count = [ @reflection.options[:limit], count ].min
          end

          return count
        end

        def has_cached_counter?
          @owner.attribute_present?(cached_counter_attribute_name)
        end

        def cached_counter_attribute_name
          "#{@reflection.name}_count"
        end

        def insert_record(record)
          set_belongs_to_association_for(record)
          record.save
        end

        def delete_records(documents)
          case @reflection.options[:dependent]
            when :destroy
              documents.each(&:destroy)
            when :delete_all
              @reflection.klass.delete(documents.map(&:id))
            else
              find(documents.map{|d| d.id }, :conditions => @association_conditions).each {|doc| doc.update_attributes({@reflection.primary_key_name => nil}, true)}
              database.commit
          end
        end

        def target_obsolete?
          false
        end

        def construct_conditions
          if @reflection.options[:as]
            @association_conditions = {"#{@reflection.options[:as]}_id".to_sym => @owner.id,
              "#{@reflection.options[:as]}_type".to_sym => @owner.class.name.to_s}
          else
            @association_conditions = {@reflection.primary_key_name => @owner.id}
          end
          @association_conditions.merge!(conditions) if conditions
        end

        def construct_scope
          create_scoping = {}
          set_belongs_to_association_for(create_scoping)
          {
            :find => { :conditions => @association_conditions, :readonly => false, :order => @reflection.options[:order], :offset => @reflection.options[:offset], :limit => @reflection.options[:limit], :include => @reflection.options[:include]},
            :create => create_scoping
          }
        end
    end
  end
end