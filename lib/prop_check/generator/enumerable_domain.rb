require 'set'

module PropCheck
  class Generator
    # Describes a finite prefix of a generator's domain.
    #
    # Traversal is breadth-first across lazy branch enumerators. This keeps a
    # large early branch from consuming the whole test budget before smaller
    # later branches are visited.
    #
    # Root values are deduplicated using Ruby's `eql?`/`hash` protocol. When two
    # generated values are equivalent, the shrink tree discovered first is used.
    class EnumerableDomain
      include Enumerable

      UNKNOWN = Object.new.freeze

      attr_reader :branches, :enumerated_count

      def self.singleton(node, exhaustive: true)
        node = LazyTree.wrap(node) unless node.is_a?(LazyTree)
        new([node], exhaustive: exhaustive)
      end

      def initialize(branches = [], exhaustive: true)
        @branches = branches.lazy
        @exhaustive = exhaustive
        @fully_traversed = false
        @seen = Set.new
        @enumerated_count = 0
      end

      def known_complete?
        @exhaustive
      end

      def exhaustive?
        @fully_traversed && @exhaustive
      end

      def each(&block)
        return to_enum(:each) unless block_given?

        active = [@branches.to_enum]

        until active.empty?
          next_active = []

          active.each do |enumerator|
            branch = next_or_nil(enumerator)
            next if branch.nil?

            visit_branch(branch, next_active, &block)
            next_active << enumerator
          end

          active = next_active
        end

        @fully_traversed = true
        self
      end

      def map_trees
        transformed = @branches.map do |branch|
          transform_branch(branch) do |tree|
            yield(tree)
          end
        end
        self.class.new(transformed, exhaustive: @exhaustive)
      end

      def reject_trees
        map_trees { |tree| yield(tree) ? nil : tree }
      end

      def bind_trees(&block)
        bound = @branches.map { |branch| bind_branch(branch, &block) }
        self.class.new(bound, exhaustive: @exhaustive)
      end

      def visit_branch(branch, active, &block)
        case branch
        when UNKNOWN
          @exhaustive = false
        when LazyTree
          if @seen.add?(branch.root)
            @enumerated_count += 1
            yield(branch)
          end
        when EnumerableDomain
          @exhaustive = false unless branch.known_complete?
          active << branch.branches
        when Enumerator
          active << branch
        else
          raise ArgumentError, "Unexpected enumerable domain branch: #{branch.inspect}"
        end
      end

      def next_or_nil(enumerator)
        enumerator.next
      rescue StopIteration
        nil
      end

      def transform_branch(branch, &block)
        case branch
        when UNKNOWN
          UNKNOWN
        when LazyTree
          block.call(branch)
        when EnumerableDomain
          branch.map_trees(&block)
        when Enumerator
          branch.map { |nested| transform_branch(nested, &block) }
        else
          raise ArgumentError, "Unexpected enumerable domain branch: #{branch.inspect}"
        end
      end

      def bind_branch(branch, &block)
        case branch
        when UNKNOWN
          UNKNOWN
        when LazyTree
          block.call(branch)
        when EnumerableDomain
          bound = branch.branches.map { |nested| bind_branch(nested, &block) }
          EnumerableDomain.new(bound, exhaustive: branch.known_complete?)
        when Enumerator
          branch.map { |nested| bind_branch(nested, &block) }
        else
          raise ArgumentError, "Unexpected enumerable domain branch: #{branch.inspect}"
        end
      end

      private
    end
  end
end
