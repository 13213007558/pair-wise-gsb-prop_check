# frozen_string_literal: true

require 'digest'
require 'pp'

module PropCheck
  module Generators
    class GeneratedFunction
      ObservedBranch = Struct.new(:arguments, :key, :tree)
      CanonicalHashKey = Struct.new(:entries) do
        def inspect
          entries.to_h.inspect
        end
      end

      attr_reader :observed_calls
      attr_reader :seed

      def initialize(value_generator, key_function, seed, generate_options)
        @value_generator = value_generator
        @key_function = key_function
        @seed = seed
        @generate_options = generate_options.reject { |key, _| key == :rng }
        @branches = {}
        @observed_calls = []
      end

      def call(argument)
        key = @key_function.call(argument)
        storage_key = encode_key(key)
        branch = @branches[storage_key]

        unless branch
          tree = @value_generator.generate(
            **@generate_options,
            rng: branch_rng(key)
          )
          branch = ObservedBranch.new([argument], key, tree)
          @branches[storage_key] = branch
          @observed_calls << [argument, tree.root]
        else
          if branch.arguments.any? { |observed_argument| observed_argument.equal?(argument) }
            return branch.tree.root
          end

          branch.arguments << argument
          @observed_calls << [argument, branch.tree.root]
        end

        branch.tree.root
      end

      def shrink_tree
        LazyTree.new(self, Enumerator.new { |yielder|
          shrink_children.each { |child| yielder << child }
        }.lazy)
      end

      def shrink_children
        @branches.values.lazy.flat_map do |branch|
          branch.tree.children.lazy.map do |shrunk_branch_tree|
            duplicate_with(branch.key, shrunk_branch_tree).shrink_tree
          end
        end
      end

      def inspect
        entries = @branches.values.flat_map do |branch|
          branch.arguments.map do |argument|
            "  #{argument.inspect} => #{branch.tree.root.inspect} (key: #{branch.key.inspect})"
          end
        end

        "#<#{self.class} seed: #{@seed.inspect}, call table:\n#{entries.join("\n")}\n>"
      end

      def pretty_print(q)
        q.text(inspect)
      end

      def duplicate_with(shrunk_key, shrunk_tree)
        duplicate = self.class.new(
          @value_generator,
          @key_function,
          @seed,
          @generate_options
        )

        @branches.each_value do |branch|
          tree = encode_key(branch.key) == encode_key(shrunk_key) ? shrunk_tree : branch.tree
          duplicate.prefill(branch.arguments, branch.key, tree)
        end

        duplicate
      end

      def prefill(arguments, key, tree)
        @branches[encode_key(key)] = ObservedBranch.new(arguments, key, tree)
        @observed_calls.concat(arguments.map { |argument| [argument, tree.root] })
      end

      private

      def encode_key(key)
        Digest::SHA256.digest("#{@seed}\0#{serialized_key(key)}".b)
      rescue TypeError
        raise ArgumentError,
              "Generated function keys must be stably serializable with Marshal, but #{key.inspect} is not. Pass a custom `key:` proc that returns a stable key."
      end

      def branch_rng(key)
        seed = Digest::SHA256.digest("#{@seed}\0#{serialized_key(key)}".b).unpack1('Q>')
        Random.new(seed)
      end

      def serialized_key(key)
        Marshal.dump(canonicalize_key(key))
      end

      def canonicalize_key(key)
        case key
        when Array
          key.map { |element| canonicalize_key(element) }
        when Hash
          entries = key.map do |hash_key, value|
            [canonicalize_key(hash_key), canonicalize_key(value)]
          end
          CanonicalHashKey.new(entries.sort_by { |hash_key, _| Marshal.dump(hash_key) })
        when Range
          Range.new(
            canonicalize_key(key.begin),
            canonicalize_key(key.end),
            key.exclude_end?
          )
        when Float
          key.zero? ? 0.0 : key
        else
          key
        end
      end
    end

    DEFAULT_FUNCTION_KEY = proc { |argument| default_function_key(argument) }

    def self.default_function_key(argument)
      case argument
      when nil, true, false, Numeric, String, Symbol
        argument
      when Array
        argument.map { |element| default_function_key(element) }
      when Hash
        argument.each_with_object({}) do |(key, value), result|
          result[default_function_key(key)] = default_function_key(value)
        end
      when Range
        Range.new(
          default_function_key(argument.begin),
          default_function_key(argument.end),
          argument.exclude_end?
        )
      else
        raise ArgumentError,
              "Cannot use #{argument.inspect} as a default generated-function argument key. Pass `function(..., key: ->(argument) { ... })` with a stable custom key."
      end
    end
  end
end
