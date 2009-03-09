# The view code uses some of the code developed by Alexander Lang (http://upstream-berlin.com/) in 
# CouchPotato.
module CouchFoo
  module ViewMethods
    
    def self.included(base)
      base.extend ClassMethods
    end
    
    module ClassMethods

      # Method that does find_by_id, find_by_username_and_type views.  If the CouchDB version is
      # greater than 0.8 it will add the counter function into the same design document but add an 
      # option to not perform it.  This makes any calls to count the number of records more efficient
      # in future as there's only one index to keep updated 
      def find_view(options)
        search_fields = search_fields(options)
        
        reduce_function = nil
        if database.version > 0.8
          reduce_function = count_documents_function
          options[:reduce] = false
        end
        
        generic_view(get_view_name(search_fields), find_by_function(search_fields), reduce_function, options)
      end

      # Find the number of documents in a view.  If the CouchDB version is greater than 0.8 then we
      # use the same view as the finder so we only need to keep one view for both finding and counting
      # on the same attributes 
      def count_view(options)
        search_fields = search_fields(options)
        
        if database.version > 0.8
          view_name = get_view_name(search_fields)
        else
          view_name = get_view_name(search_fields, "count")
        end
        
        options[:return_json] = true
        result = generic_view(view_name, find_by_function(search_fields), count_documents_function, options)
        
        result['rows'].first['value'] rescue 0
      end

      # Perform a view operation with passed name, functions and options
      def generic_view(view_name, find_function, reduce_function = nil, options = {})
        return_json = options.delete(:return_json)
        order = options.delete(:order) || default_sort_order
        readonly = options.delete(:readonly)
        
        if options.delete(:view_type) == :slow
          result = query_slow_view(find_function, reduce_function, options)
        else
          result = query_view(view_name, find_function, reduce_function, options)
        end
        
        if return_json
          result
        else
          instantiate_instances(result, readonly, order)
        end
      end
      
      private
      # Takes JSON and makes objects.  Also handles readonly and ordering
      def instantiate_instances(result, readonly = false, order = false)
        documents = result['rows'].map{|doc| doc['value']}.map{|attrs| instantiate(attrs) }
        documents.each { |record| record.readonly! } if readonly
        documents.sort! {|a,b| a.send(order) <=> b.send(order)} if order
        documents
      end
      
      # Shouldn't really be used apart from debugging
      def query_slow_view(map_function, reduce_function, options)
        database.slow_view({:map => map_function, :reduce => reduce_function}, search_values(options))
      end
      
      # Assume the view exists and if we get a 404 then create the view before doing the query again
      def query_view(view_name, map_function, reduce_function, options)
        search_values = search_values(options)
        begin
          do_query_view(view_name, search_values)
        rescue DocumentNotFound
          create_view(view_name, map_function, reduce_function)
          do_query_view(view_name, search_values)
        end
      end
      
      # Returns a name for a view
      def get_view_name(search_fields, prefix = "find")
        prefix + "_by_" + search_fields.join('_and_')
      end
      
      # Submit query to database
      def do_query_view(view_name, view_options)
        database.view "#{self.name.underscore}/#{view_name}", view_options
      end
      
      # Create a named view.  If the design document exists we append to the document, else we create it
      def create_view(view_name, map_function, reduce_function = nil)
        design_doc = database.get "_design/#{self.name.underscore}" rescue nil
        if design_doc
          design_doc["views"][view_name] = {:map => map_function, :reduce => reduce_function}
        else
          design_doc = {
            "_id" => "_design/#{self.name.underscore}",
              :views => {
                view_name => {
                  :map => map_function,
                  :reduce => reduce_function
                }
              }
            }
        end
        database.save(design_doc)
      end
      
      # Find the fields to search on, :view takes preference if provided
      def search_fields(options)
        search_fields = options.delete(:use_key)
        if search_fields
          search_fields = [search_fields] unless search_fields.is_a?(Array)
          search_fields = search_fields.sort_by{|f| f.to_s}
        else
          search_fields = options[:conditions].to_a.sort_by{|f| f.first.to_s}.map(&:first)
        end

        # If no seach field fall back on :created_at or :id
        if search_fields.empty?
          if property_names.include?(:created_at)
            search_fields << :created_at
          else
            search_fields << :_id
          end
        end

        # Deal with missing underscore automatically
        search_fields << :_id if search_fields.delete(:id)
        search_fields << :_rev if search_fields.delete(:rev)
        search_fields
      end
      
      # Find the values that will be used to select the appropriate records.  In CouchDB this works
      # as keys on a view, so if you wanted all documents where cost=5 you would create a view that
      # exposes cost as the key and use a key=5 query string on the database query.  Ranges are also
      # supported by using startkey and endkey, for example startkey=4&endkey=9 would find all
      # documents where the cost is between 4 and 9.
      #  
      # Multiple part keys are also possible so if you wanted all documents where the cost is between
      # 4 and 9 and the weight between 1 and 3 you could use (assuming you exposed the key as [cost, weight])
      # startkey=[4,1]&endkey=[9,3]
      #
      # As of CouchDB 0.9 there is another option to find documents with a specific list of keys.      
      # This allows you to pass an explicit list, for example to find all clothes with size 6, 8 or 10
      # where the clothes size is exposed as a key, you would use keys=[6,8,10]
      #
      # Note: :keys works differently at the CouchDB level (requiring a POST rather than a GET) and is
      # currently not usable with any other condition (such as :startkey, :endkey)
      def search_values(view_options)
        conditions = view_options.delete(:conditions)
        switch_limit_name_if_necessary!(view_options)
        search_values = conditions.to_a.sort_by{|f| f.first.to_s}.map(&:last)
        result = {}

        # Get the hash of values to use
        if search_values.select{|v| v.is_a?(Range)}.any?
          result = {:startkey => search_values.map{|v| v.is_a?(Range) ? v.first : v}, 
                  :endkey => search_values.map{|v| v.is_a?(Range) ? v.last : v}}.merge(view_options)
        elsif search_values.select{|v| v.is_a?(Array)}.any?
          result = {:keys => prepare_multi_key_search(search_values)}.merge(view_options)
        else
          result = view_options.merge(search_values.any? ? {:key => search_values} : {})
        end
        
        result.delete_if {|key,value| value.nil? }
        switch_mysql_terms!(result)
        switch_keys_if_descending!(result)
        ensure_keys_are_arrays!(result)
        result
      end
    
      # Deal with legacy CouchDB versions
      def switch_limit_name_if_necessary!(view_options)
        if (database.version < 0.9)
          limit = view_options.delete(:limit)
          view_options[:count] = limit unless limit.nil?
        end
      end
      
      # We allow MySQL options on finders for compatability and switch them under the covers
      def switch_mysql_terms!(result)
        offset = result.delete(:offset)
        result[:skip] = offset if offset
      end
      
      # Swap start and end keys if user has set descending (as CouchDB descends before applying
      # the key filtering)
      def switch_keys_if_descending!(result)
        if result[:descending]
          startkey = result.delete(:startkey)
          endkey = result.delete(:endkey)
          result[:startkey] = endkey unless endkey.nil?
          result[:endkey] = startkey unless startkey.nil?
        end
      end
    
      # Ensure start and end keys are specified as arrays
      def ensure_keys_are_arrays!(result)
        if result[:startkey] && !result[:startkey].is_a?(Array)
          result[:startkey] = [result[:startkey]] 
        end
        if result[:endkey] && !result[:endkey].is_a?(Array)
          result[:endkey] = [result[:endkey]]
        end
      end
    
      def prepare_multi_key_search(values)
        array = values.select{|v| v.is_a?(Array)}.first
        index = values.index array
        array.map do |item|
          copy = values.dup
          copy[index] = item
          copy
        end
      end
    
      # Map function for find
      def find_by_function(search_fields)
        "function(doc) {
              if(doc.ruby_class == '#{self.name}') {
                emit(
                  [#{(search_fields).map{|attr| 'doc.' + attr.to_s}.join(', ')}], doc
                );
              }
              }"
      end
      
      # Reduce function for counting the number of matched documents
      def count_documents_function
        "function(keys, values) {
          return values.length;
        }"
      end
    end
  end
end
