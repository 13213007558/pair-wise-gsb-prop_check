require_relative 'generator/enumerable_domain'

module PropCheck
  ##
  # A `Generator` is a special kind of 'proc' that,
  # given a size an random number generator state,
  # will generate a (finite) LazyTree of output values:
  #
  # The root of this tree is the value to be used during testing,
  # and the children are 'smaller' values related to the root,
  # to be used during the shrinking phase.
  class Generator
    @@default_size = 10
    @@default_rng =
      # Backwards compatibility: Random::DEFAULT is deprecated in Ruby 3.x
      # but required in Ruby 2.x and 1.x
      if RUBY_VERSION.to_i >= 3
        Random
      else
        Random::DEFAULT
      end
    @@max_consecutive_attempts = 100
    @@default_kwargs = { size: @@default_size, rng: @@default_rng,
                         max_consecutive_attempts: @@max_consecutive_attempts }

    ##
    # Being a special kind of Proc, a Generator wraps a block.
    def initialize(enumerable_domain: nil, &block)
      @block = block
      @enumerable_domain_block = enumerable_domain
    end

    ##
    # Given a `size` (integer) and a random number generator state `rng`,
    # generate a LazyTree.
    def generate(**kwargs)
      kwargs = @@default_kwargs.merge(kwargs)
      max_consecutive_attempts = kwargs[:max_consecutive_attempts]

      (0..max_consecutive_attempts).each do
        res = @block.call(**kwargs)
        next if res.root == :"_PropCheck.filter_me"

        return res
      end

      raise Errors::GeneratorExhaustedError, ''"
      Exhausted #{max_consecutive_attempts} consecutive generation attempts.

      Probably too few generator results were adhering to a `where` condition.
      "''
    end

    ##
    # Returns a lazy enumerable domain when this generator can enumerate some or
    # all of its values. Returns `nil` when its domain is infinite or unknown.
    def enumerable_domain(**kwargs)
      return nil unless @enumerable_domain_block

      kwargs = @@default_kwargs.merge(kwargs)
      @enumerable_domain_block.call(**kwargs)
    end

    ##
    # Generates a value, and only return this value
    # (drop information for shrinking)
    #
    #   >> Generators.integer.call(size: 1000, rng: Random.new(42))
    #   => 126
    def call(**kwargs)
      generate(**kwargs).root
    end

    ##
    # Returns `num_of_samples` values from calling this Generator.
    # This is mostly useful for debugging if a generator behaves as you intend it to.
    def sample(num_of_samples = 10, **kwargs)
      num_of_samples.times.map do
        call(**kwargs)
      end
    end

    ##
    # Creates a 'constant' generator that always returns the same value,
    # regardless of `size` or `rng`.
    #
    # Keen readers may notice this as the Monadic 'pure'/'return' implementation for Generators.
    #
    #   >> Generators.integer.bind { |a| Generators.integer.bind { |b| Generator.wrap([a , b]) } }.call(size: 100, rng: Random.new(42))
    #   => [2, 79]
    def self.wrap(val)
      tree = LazyTree.wrap(val)
      Generator.new(enumerable_domain: ->(_) { Generator::EnumerableDomain.singleton(tree) }) { tree }
    end

    ##
    # Create a generator whose implementation depends on the output of another generator.
    # this allows us to compose multiple generators.
    #
    # Keen readers may notice this as the Monadic 'bind' (sometimes known as '>>=') implementation for Generators.
    #
    #   >> Generators.integer.bind { |a| Generators.integer.bind { |b| Generator.wrap([a , b]) } }.call(size: 100, rng: Random.new(42))
    #   => [2, 79]
    def bind(&generator_proc)
      # Generator.new do |size, rng|
      #   outer_result = generate(size, rng)
      #   outer_result.map do |outer_val|
      #     inner_generator = generator_proc.call(outer_val)
      #     inner_generator.generate(size, rng)
      #   end.flatten
      # end
      enumerable_domain = lambda do |**kwargs|
        outer_domain = self.enumerable_domain(**kwargs)
        next nil unless outer_domain

        outer_branches = outer_domain.branches.map do |outer_branch|
          bind_enumerable_branch(outer_branch, generator_proc, kwargs)
        end
        Generator::EnumerableDomain.new(outer_branches, exhaustive: outer_domain.known_complete?)
      end

      Generator.new(enumerable_domain: enumerable_domain) do |**kwargs|
        outer_result = generate(**kwargs)
        outer_result.bind do |outer_val|
          inner_generator = generator_proc.call(outer_val)
          inner_generator.generate(**kwargs)
        end
      end
    end

    ##
    # Creates a new Generator that returns a value by running `proc` on the output of the current Generator.
    #
    #   >> Generators.choose(32..128).map(&:chr).call(size: 10, rng: Random.new(42))
    #   => "S"
    def map(&proc)
      enumerable_domain = lambda do |**kwargs|
        source_domain = self.enumerable_domain(**kwargs)
        next nil unless source_domain

        source_domain
          .map_trees { |tree| tree.map(&proc) }
          .reject_trees { |tree| tree.root == :"_PropCheck.filter_me" }
      end

      Generator.new(enumerable_domain: enumerable_domain) do |**kwargs|
        result = generate(**kwargs)
        result.map(&proc)
      end
    end

    ##
    # Turns a generator returning `x` into a generator returning `[x, config]`
    # where `config` is the current `PropCheck::Property::Configuration`.
    # This can be used to inspect the configuration inside a `#map` or `#where`
    # and act on it.
    #
    #  >> example_config = PropCheck::Property::Configuration.new(default_epoch: Date.new(2022, 11, 22))
    #  >> generator = Generators.choose(0..100).with_config.map { |int, conf| Date.jd(conf[:default_epoch].jd + int) }
    #  >> generator.call(size: 10, rng: Random.new(42), config: example_config)
    #  => Date.new(2023, 01, 12)
    def with_config
      enumerable_domain = lambda do |**kwargs|
        source_domain = self.enumerable_domain(**kwargs)
        next nil unless source_domain

        source_domain.map_trees do |tree|
          tree.map { |val| [val, kwargs[:config]] }
        end
      end

      Generator.new(enumerable_domain: enumerable_domain) do |**kwargs|
        result = generate(**kwargs)
        result.map { |val| [val, kwargs[:config]] }
      end
    end

    ##
    # Creates a new Generator that only produces a value when the block `condition` returns a truthy value.
    def where(&condition)
      map do |result|
        # if condition.call(*result)
        if PropCheck::Helper.call_splatted(result, &condition)
          result
        else
          :"_PropCheck.filter_me"
        end
      end
    end

    ##
    # Resizes the generator to either grow faster or smaller than normal.
    #
    # `proc` takes the current size as input and is expected to return the new size.
    # a size should always be a nonnegative integer.
    #
    #    >> Generators.integer.resize{}
    def resize(&proc)
      enumerable_domain = lambda do |size:, **other_kwargs|
        new_size = proc.call(size)
        self.enumerable_domain(**other_kwargs, size: new_size)
      end

      Generator.new(enumerable_domain: enumerable_domain) do |size:, **other_kwargs|
        new_size = proc.call(size)
        generate(**other_kwargs, size: new_size)
      end
    end

    private

    def bind_enumerable_branch(branch, generator_proc, kwargs)
      case branch
      when Generator::EnumerableDomain::UNKNOWN
        Generator::EnumerableDomain::UNKNOWN
      when LazyTree
        bind_enumerable_tree(branch, generator_proc, kwargs)
      when Generator::EnumerableDomain
        nested_branches = branch.branches.map do |nested_branch|
          bind_enumerable_branch(nested_branch, generator_proc, kwargs)
        end
        Generator::EnumerableDomain.new(nested_branches, exhaustive: branch.known_complete?)
      when Enumerator
        branch.map { |nested_branch| bind_enumerable_branch(nested_branch, generator_proc, kwargs) }
      else
        raise ArgumentError, "Unexpected enumerable domain branch: #{branch.inspect}"
      end
    end

    def bind_enumerable_tree(outer_tree, generator_proc, kwargs)
      inner_generator = generator_proc.call(outer_tree.root)
      inner_domain = inner_generator.enumerable_domain(**kwargs)

      unless inner_domain
        return Generator::EnumerableDomain.new(
          [inner_generator.generate(**kwargs), Generator::EnumerableDomain::UNKNOWN],
          exhaustive: false
        )
      end

      inner_domain.map_trees do |inner_tree|
        bind_trees(outer_tree, inner_tree, generator_proc, kwargs)
      end
    end

    def bind_trees(outer_tree, inner_tree, generator_proc, kwargs)
      outer_children = outer_tree.children.map do |outer_child|
        outer_child.bind do |outer_value|
          generator_proc.call(outer_value).generate(**kwargs)
        end
      end
      children = PropCheck::Helper.lazy_append(inner_tree.children, outer_children)
      LazyTree.new(inner_tree.root, children)
    end
  end
end
