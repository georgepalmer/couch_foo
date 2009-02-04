Gem::Specification.new do |s|
  s.name = %q{couch_foo}
  s.version = "0.0.0"
  s.add_dependency "json", [">=0"]
  s.add_dependency "activesupport", [">=0"]
  s.add_dependency "jchris-couchrest", [">=0.9.12"]
  s.add_dependency "uuid", [">=2.0"]
  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["George Palmer"]
  s.date = %q{2009-02-04}
  s.description = %q{CouchFoo provides an ActiveRecord API for CouchDB}
  s.email = %q{george.palmer@gmail.com}
  s.files = ["VERSION.yml", "README.rdoc", "lib/boolean.rb", "lib/couch_foo.rb", "lib/couch_foo", "lib/couch_foo/database.rb", "lib/couch_foo/dirty.rb", "lib/couch_foo/associations.rb", "lib/couch_foo/associations", "lib/couch_foo/associations/has_one_association.rb", "lib/couch_foo/associations/association_collection.rb", "lib/couch_foo/associations/has_many_association.rb", "lib/couch_foo/associations/belongs_to_association.rb", "lib/couch_foo/associations/association_proxy.rb", "lib/couch_foo/associations/belongs_to_polymorphic_association.rb", "lib/couch_foo/associations/has_and_belongs_to_many_association.rb", "lib/couch_foo/observer.rb", "lib/couch_foo/base.rb", "lib/couch_foo/calculations.rb", "lib/couch_foo/view_methods.rb", "lib/couch_foo/attribute_methods.rb", "lib/couch_foo/named_scope.rb", "lib/couch_foo/callbacks.rb", "lib/couch_foo/reflection.rb", "lib/couch_foo/validations.rb", "lib/couch_foo/timestamp.rb", "test/couch_foo_test.rb", "test/test_helper.rb"]
  s.has_rdoc = true
  s.homepage = %q{http://github.com/georgepalmer/couch_foo}
  s.rdoc_options = ["--inline-source", "--charset=UTF-8"]
  s.require_paths = ["lib"]
  s.rubygems_version = %q{1.2.0}
  s.summary = %q{CouchFoo provides an ActiveRecord API for CouchDB}

  if s.respond_to? :specification_version then
    current_version = Gem::Specification::CURRENT_SPECIFICATION_VERSION
    s.specification_version = 2

    if current_version >= 3 then
    else
    end
  else
  end
end
