module CouchFoo
# this class was taken from the issues list on Couch Foo
# see: http://github.com/zedalaye
# http://github.com/georgepalmer/couch_foo/issues#issue/1

  class DatabaseVersion

    attr_accessor :major, :minor, :patch

    def initialize(version)
      self.major = 0
      self.minor = 0
      self.patch = 0
      self.version = version
    end

    def version=(version)
      if version.to_s =~ /(\d)\.(\d)\.(\d+)/
        self.major = $1.to_i
        self.minor = $2.to_i
        self.patch = $3.to_i
      end
    end

    def > (version)
      v = DatabaseVersion.new(version)
      (self.major > v.major) || 
      ((self.major == v.major) && (self.minor > v.minor)) ||
      ((self.major == v.major) && (self.minor == v.minor) && (self.patch > v.patch))
    end

    def < (version)
      v = DatabaseVersion.new(version)
      (v.major > self.major) || 
      ((v.major == self.major) && (v.minor > self.minor)) ||
      ((v.major == self.major) && (v.minor == self.minor) && (v.patch > self.patch))
    end
  end
end