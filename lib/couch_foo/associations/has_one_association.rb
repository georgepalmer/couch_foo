module CouchFoo
  module Associations
    class HasOneAssociation < BelongsToAssociation #:nodoc:
      def initialize(owner, reflection)
        super
        construct_conditions
      end

      def create(attrs = {}, replace_existing = true)
        new_record(replace_existing) { |klass| klass.create(attrs) }
      end

      def create!(attrs = {}, replace_existing = true)
        new_record(replace_existing) { |klass| klass.create!(attrs) }
      end

      def build(attrs = {}, replace_existing = true)
        new_record(replace_existing) { |klass| klass.new(attrs) }
      end

      def replace(obj, dont_save = false)
        load_target

        unless @target.nil? || @target == obj
          if dependent? && !dont_save
            @target.destroy unless @target.new_record?
            @owner.clear_association_cache
          else
            @target[@reflection.primary_key_name] = nil
            @target.save unless @owner.new_record? || @target.new_record?
          end
        end

        if obj.nil?
          @target = nil
        else
          raise_on_type_mismatch(obj)
          set_belongs_to_association_for(obj)
          @target = (AssociationProxy === obj ? obj.target : obj)
        end

        @loaded = true

        unless @owner.new_record? or obj.nil? or dont_save
          return (obj.save ? self : false)
        else
          return (obj.nil? ? nil : self)
        end
      end
            
      private
        def find_target
          @reflection.klass.find(:first, 
            :conditions => @association_conditions,
            :order      => @reflection.options[:order], 
            :include    => @reflection.options[:include],
            :readonly   => @reflection.options[:readonly]
          )
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
          { :create => create_scoping }
        end

        def new_record(replace_existing)
          # Make sure we load the target first, if we plan on replacing the existing
          # instance. Otherwise, if the target has not previously been loaded
          # elsewhere, the instance we create will get orphaned.
          load_target if replace_existing
          record = @reflection.klass.send(:with_scope, :create => construct_scope[:create]) { yield @reflection.klass }

          if replace_existing
            replace(record, true) 
          else
            record[@reflection.primary_key_name] = @owner.id unless @owner.new_record?
            self.target = record
          end

          record
        end
    end
  end
end