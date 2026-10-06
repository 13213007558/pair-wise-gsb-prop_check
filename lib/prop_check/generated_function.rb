# frozen_string_literal: true

module PropCheck
  class GeneratedFunction
    DEFAULT_KEY_FUNCTION = proc { |*args| args.length == 1 ? args.fetch(0) : args }

    FNV_OFFSET_BASIS = 0xcbf29ce484222325
    FNV_PRIME = 0x100000001b3
    FNV_MASK = 0xffffffffffffffff

    module StableKey
      module_function

      def encode(value, encoding_stack = [])
        case value
        when nil then [:__prop_check_nil__]
        when true then [:__prop_check_true__]
        when false then [:__prop_check_false__]
        when Integer then [:__prop_check_integer__, value]
        when Float
          raise ArgumentError, 'Float::NAN is not a stable key' if value.nan?

          [:__prop_check_float__, value]
        when Rational then [:__prop_check_rational__, value.numerator, value.denominator]
        when Complex
          [:__prop_check_complex__, encode(value.real), encode(value.imaginary)]
        when String then [:__prop_check_string__, value.dup.freeze]
        when Symbol then [:__prop_check_symbol__, value]
        when Array
          encoded = with_encoding_guard(value, encoding_stack) do
            value.map { |element| encode(element, encoding_stack) }
          end
          [:__prop_check_array__, encoded].freeze
        when Hash
          pairs = with_encoding_guard(value, encoding_stack) do
            value.map do |key, pair_value|
              [encode(key, encoding_stack), encode(pair_value, encoding_stack)]
            end.sort_by { |key, _| Marshal.dump(key) }
          end
          canonical = pairs.each_with_object({}) { |(key, pair_value), acc| acc[key] = pair_value }
          [:__prop_check_hash__, canonical].freeze
        when Range
          [:__prop_check_range__, encode(value.begin), value.exclude_end?, encode(value.end)].freeze
        when Regexp
          [:__prop_check_regexp__, value.source.dup.freeze, value.options].freeze
        else
          raise ArgumentError, "cannot stably encode #{value.class}"
        end
      end

      def with_encoding_guard(value, encoding_stack)
        object_id = value.object_id
        if encoding_stack.include?(object_id)
          raise ArgumentError, "cannot stably encode recursive #{value.class}"
        end

        encoding_stack.push(object_id)
        begin
          yield
        ensure
          encoding_stack.pop
        end
      end
    end

    attr_reader :base_seed

    def initialize(key_function, return_generator, generate_options, base_seed,
                   mapping: {}, value_trees: {}, call_log: [])
      @key_function = key_function
      @return_generator = return_generator
      @generate_options = generate_options.dup
      @base_seed = base_seed
      @mapping = mapping.dup
      @value_trees = value_trees.dup
      @call_log = call_log.dup
      @mutex = Mutex.new
    end

    def call(*arguments)
      original_argument = arguments.length == 1 ? arguments.fetch(0) : arguments
      raw_key = @key_function.call(*arguments)
      key = encode_key(raw_key) { unstable_key_message(raw_key) }

      @mutex.synchronize do
        if @mapping.key?(key)
          value = @mapping.fetch(key)
          log_call(original_argument, raw_key, key, value) unless observed_call?(original_argument, raw_key, value)
          next value
        end

        tree = generate_value_tree(key)
        value = tree.root
        @mapping[key] = value
        @value_trees[key] = tree
        log_call(original_argument, raw_key, key, value)
        value
      end
    end

    def call_table
      @call_log.map do |entry|
        {
          argument: entry.fetch(:argument),
          key: entry.fetch(:raw_key),
          output: entry.fetch(:output)
        }
      end
    end

    def shrink_children
      logged_keys = {}

      @call_log.lazy.each_with_index.flat_map do |entry, _index|
        key = entry.fetch(:key)
        next [].lazy if logged_keys.key?(key)

        logged_keys[key] = true
        tree = @value_trees.fetch(key)
        tree.children.map do |child_tree|
          shrunken_function = with_replacement(key, child_tree.root, child_tree)
          LazyTree.new(shrunken_function, shrunken_function.shrink_children)
        end
      end
    end

    def inspect
      "#<#{self.class.name} size: #{@generate_options.fetch(:size).inspect}, " \
        "base_seed: #{@base_seed.inspect}, calls: #{formatted_call_table.inspect}>"
    end
    alias to_s inspect

    def pretty_print(printer)
      printer.text(inspect)
    end

    private

    def encode_key(raw_key)
      StableKey.encode(raw_key)
    rescue ArgumentError
      raise ArgumentError, yield
    end

    def unstable_key_message(raw_key)
      if @key_function.equal?(DEFAULT_KEY_FUNCTION)
        "#{self.class.name} cannot stably encode the generated function argument " \
          "#{raw_key.inspect} (#{raw_key.class}). Pass a custom key function to " \
          'Generators.function whose return value has stable #hash and #eql? semantics.'
      else
        'the custom key function passed to Generators.function returned ' \
          "#{raw_key.inspect} (#{raw_key.class}), which cannot be stably encoded. " \
          'Return nil, a Boolean, Numeric, String, Symbol, Array, Hash, Range, or Regexp.'
      end
    end

    def generate_value_tree(key)
      rng = Random.new(seed_for(key))
      @return_generator.clone.generate(**@generate_options, rng: rng)
    end

    def seed_for(key)
      hash = FNV_OFFSET_BASIS.dup
      Marshal.dump([:__prop_check_generated_function__, @base_seed, key]).bytes.each do |byte|
        hash ^= byte
        hash *= FNV_PRIME
      end
      hash & FNV_MASK
    end

    def log_call(argument, raw_key, key, value)
      @call_log.push(argument: argument, key: key, raw_key: raw_key, output: value)
    end

    def observed_call?(argument, raw_key, value)
      @call_log.any? do |entry|
        entry.fetch(:argument) == argument &&
          entry.fetch(:raw_key).eql?(raw_key) &&
          entry.fetch(:output) == value
      end
    end

    def with_replacement(key, value, tree)
      shrunken_call_log = @call_log.map do |entry|
        if entry.fetch(:key) == key
          entry.merge(output: value)
        else
          entry.dup
        end
      end

      self.class.new(
        @key_function,
        @return_generator,
        @generate_options,
        @base_seed,
        mapping: @mapping.merge(key => value),
        value_trees: @value_trees.merge(key => tree),
        call_log: shrunken_call_log
      )
    end

    def formatted_call_table
      @call_log.map do |entry|
        {
          argument: entry.fetch(:argument),
          key: entry.fetch(:raw_key),
          output: entry.fetch(:output)
        }
      end
    end
  end
end
