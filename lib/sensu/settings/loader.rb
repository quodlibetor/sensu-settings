require "sensu/settings/validator"
require "multi_json"

module Sensu
  module Settings
    class Loader
      # @!attribute [r] warnings
      #   @return [Array] loader warnings.
      attr_reader :warnings

      # @!attribute [r] loaded_files
      #   @return [Array] loaded config files.
      attr_reader :loaded_files

      def initialize
        @warnings = []
        @settings = {
          :checks => {},
          :filters => {},
          :mutators => {},
          :handlers => {}
        }
        @indifferent_access = false
        @loaded_files = []
        self.class.create_category_methods
      end

      # Create setting category accessors and methods to test the
      # existence of definitions. Called in initialize().
      def self.create_category_methods
        CATEGORIES.each do |category|
          define_method(category) do
            setting_category(category)
          end
          method_name = category.to_s.chop + "_exists?"
          define_method(method_name.to_sym) do |name|
            definition_exists?(category, name)
          end
        end
      end

      # Access settings as an indifferent hash.
      #
      # @return [Hash] settings.
      def to_hash
        unless @indifferent_access
          indifferent_access!
        end
        @settings
      end

      # Retrieve the value object corresponding to a key, acting like
      # a Hash object.
      #
      # @param [String, Symbol] key.
      # @return [Object] value for key.
      def [](key)
        to_hash[key]
      end

      # Load settings from the environment.
      # Loads: RABBITMQ_URL, REDIS_URL, REDISTOGO_URL, API_PORT, PORT
      def load_env
        if ENV["RABBITMQ_URL"]
          @settings[:rabbitmq] = ENV["RABBITMQ_URL"]
          warning(@settings[:rabbitmq], "using rabbitmq url environment variable")
        end
        ENV["REDIS_URL"] ||= ENV["REDISTOGO_URL"]
        if ENV["REDIS_URL"]
          @settings[:redis] = ENV["REDIS_URL"]
          warning(@settings[:redis], "using redis url environment variable")
        end
        ENV["API_PORT"] ||= ENV["PORT"]
        if ENV["API_PORT"]
          @settings[:api] ||= {}
          @settings[:api][:port] = ENV["API_PORT"].to_i
          warning(@settings[:api], "using api port environment variable")
        end
        @indifferent_access = false
      end

      # Load settings from a JSON file.
      #
      # @param [String] file path.
      def load_file(file)
        if File.file?(file) && File.readable?(file)
          begin
            warning(file, "loading config file")
            contents = IO.read(file)
            config = MultiJson.load(contents, :symbolize_keys => true)
            merged = deep_merge(@settings, config)
            unless @loaded_files.empty?
              changes = deep_diff(@settings, merged)
              warning(changes, "config file applied changes")
            end
            @settings = merged
            @indifferent_access = false
            @loaded_files << file
          rescue MultiJson::ParseError => error
            warning(file, "config file must be valid json")
            warning(file, "ignoring config file")
          end
        else
          warning(file, "config file does not exist or is not readable")
          warning(file, "ignoring config file")
        end
      end

      # Load settings from files in a directory. Files may be in
      # nested directories.
      #
      # @param [String] directory path.
      def load_directory(directory)
        warning(directory, "loading config files from directory")
        path = directory.gsub(/\\(?=\S)/, "/")
        Dir.glob(File.join(path, "**/*.json")).each do |file|
          load_file(file)
        end
      end

      # Set Sensu settings related environment variables. This method
      # currently sets SENSU_CONFIG_FILES, a colon delimited list of
      # loaded config files.
      def set_env
        ENV["SENSU_CONFIG_FILES"] = @loaded_files.join(":")
      end

      # Load settings from the environment and the paths provided, set
      # appropriate environment variables.
      #
      # @param [Hash] options
      # @option options [String] :config_file to load.
      # @option options [String] :config_dir to load.
      # @return [Hash] loaded settings.
      def load(options={})
        load_env
        if options[:config_file]
          load_file(options[:config_file])
        end
        if options[:config_dir]
          load_directory(options[:config_dir])
        end
        set_env
        to_hash
      end

      # Validate the loaded settings.
      #
      # @return [Array] validation failures.
      def validate!
        service = ::File.basename($0).split("-").last
        validator = Validator.new
        validator.run(@settings, service)
      end

      private

      # Retrieve setting category definitions.
      #
      # @param [Symbol] category to retrive.
      # @return [Array<Hash>] category definitions.
      def setting_category(category)
        @settings[category].map do |name, details|
          details.merge(:name => name.to_s)
        end
      end

      # Check to see if a definition exists in a category.
      #
      # @param [Symbol] category to inspect for the definition.
      # @param [String] name of definition.
      # @return [TrueClass, FalseClass]
      def definition_exists?(category, name)
        @settings[category].has_key?(name.to_sym)
      end

      # Creates an indifferent hash.
      #
      # @return [Hash] indifferent hash.
      def indifferent_hash
        Hash.new do |hash, key|
          if key.is_a?(String)
            hash[key.to_sym]
          end
        end
      end

      # Create a copy of a hash with indifferent access.
      #
      # @param hash [Hash] hash to make indifferent.
      # @return [Hash] indifferent version of hash.
      def with_indifferent_access(hash)
        hash = indifferent_hash.merge(hash)
        hash.each do |key, value|
          if value.is_a?(Hash)
            hash[key] = with_indifferent_access(value)
          end
        end
      end

      # Update settings to have indifferent access.
      def indifferent_access!
        @settings = with_indifferent_access(@settings)
        @indifferent_access = true
      end

      # Deep merge two hashes.
      #
      # @param [Hash] hash_one to serve as base.
      # @param [Hash] hash_two to merge in.
      def deep_merge(hash_one, hash_two)
        merged = hash_one.dup
        hash_two.each do |key, value|
          merged[key] = case
          when hash_one[key].is_a?(Hash) && value.is_a?(Hash)
            deep_merge(hash_one[key], value)
          when hash_one[key].is_a?(Array) && value.is_a?(Array)
            hash_one[key].concat(value).uniq
          else
            value
          end
        end
        merged
      end

      # Compare two hashes.
      #
      # @param [Hash] hash_one to compare.
      # @param [Hash] hash_two to compare.
      # @return [Hash] comparison diff hash.
      def deep_diff(hash_one, hash_two)
        keys = hash_one.keys.concat(hash_two.keys).uniq
        keys.inject(Hash.new) do |diff, key|
          unless hash_one[key] == hash_two[key]
            if hash_one[key].is_a?(Hash) && hash_two[key].is_a?(Hash)
              diff[key] = deep_diff(hash_one[key], hash_two[key])
            else
              diff[key] = [hash_one[key], hash_two[key]]
            end
          end
          diff
        end
      end

      # Record a warning for an object.
      #
      # @param object [Object] under suspicion.
      # @param message [String] warning message.
      # @return [Array] current warnings.
      def warning(object, message)
        @warnings << {
          :object => object,
          :message => message
        }
      end
    end
  end
end
