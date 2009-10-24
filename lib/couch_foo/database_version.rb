module CouchFoo


  class DatabaseVersion

    attr_accessor :major, :minor

    def initialize(version)
      self.major = 0
      self.minor = 0
      self.version = version
    end

    def version=(version)
      if version.to_s =~ /(\d)\.(\d+)/
        self.major = $1.to_i
        self.minor = $2.to_i
      end
    end

    def > (version)
      v = DatabaseVersion.new(version)
      (self.major > v.major) || ((self.major = v.major) && (self.minor > v.minor))
    end

    def < (version)
      v = DatabaseVersion.new(version)
      (v.major > self.major) || ((v.major = self.major) && (v.minor > self.minor))
    end

  end
end