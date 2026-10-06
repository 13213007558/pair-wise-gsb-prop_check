require 'prop_check/lazy_tree'
require 'prop_check/property/configuration'
require 'prop_check/property/shrinker'

RSpec.describe PropCheck::Property::Shrinker do
  def config(**overrides)
    PropCheck::Property::Configuration.new.merge(
      max_shrink_steps: 100,
      max_shrink_candidates: 100,
      **overrides
    )
  end

  def shrink(tree, original_exception, **overrides, &property)
    described_class.call(
      tree,
      StringIO.new,
      PropCheck::Hooks.new,
      config(**overrides),
      original_exception,
      &property
    )
  end

  it 'keeps exploring through a mismatched failure to a smaller matching failure' do
    tree = PropCheck::LazyTree.new(
      :original,
      [
        PropCheck::LazyTree.new(
          :wrong,
          [PropCheck::LazyTree.new(:matching)]
        )
      ].lazy
    )

    property = proc do |value|
      raise ArgumentError, 'business assertion' if value == :original
      raise ZeroDivisionError, 'different failure' if value == :wrong
      raise ArgumentError, 'same business assertion' if value == :matching
    end

    result, exception, steps, status = shrink(
      tree,
      ArgumentError.new('business assertion'),
      failure_classifier: proc { |error, _input| error.class }
    ) { |value| property.call(value) }

    expect(result).to eq(:matching)
    expect(exception).to be_a(ArgumentError)
    expect(exception.message).to eq('same business assertion')
    expect(steps).to eq(2)
    expect(status).to include(complete: true)
  end

  it 'explores lower-complexity candidates before higher-complexity ones' do
    tree = PropCheck::LazyTree.new(
      10,
      [
        PropCheck::LazyTree.new(9),
        PropCheck::LazyTree.new(1),
        PropCheck::LazyTree.new(5)
      ].lazy
    )
    checked = []

    result, = shrink(
      tree,
      ArgumentError.new,
      failure_classifier: proc { |error, _input| error.class },
      complexity_function: proc { |input| input }
    ) do |value|
      checked << value
      raise ArgumentError if value < 5
    end

    expect(result).to eq(1)
    expect(checked).to eq([1, 5, 9])
  end

  it 'deduplicates candidates using the caller-provided stable key' do
    generated_roots = []
    duplicate = PropCheck::LazyTree.new(1)
    children = Enumerator.new do |yielder|
      [2, duplicate.root, duplicate.root].each do |value|
        generated_roots << value
        yielder << (value == 1 ? duplicate : PropCheck::LazyTree.new(value))
      end
    end
    tree = PropCheck::LazyTree.new(0, children.lazy)
    calls = []

    shrink(
      tree,
      ArgumentError.new,
      failure_classifier: proc { |error, _input| error.class },
      candidate_key_function: proc { |input| input }
    ) do |value|
      calls << value
      raise ArgumentError
    end

    expect(generated_roots).to eq([2, 1, 1])
    expect(calls).to eq([2, 1])
  end

  it 'limits generated candidates independently of property executions' do
    children = Enumerator.new { |yielder| (1..).each { |value| yielder << PropCheck::LazyTree.new(value) } }
    wide_tree = PropCheck::LazyTree.new(0, children.lazy)
    calls = 0

    _result, _exception, steps, status = shrink(
      wide_tree,
      ArgumentError.new,
      max_shrink_candidates: 2,
      max_shrink_steps: 3,
      failure_classifier: proc { |error, _input| error.class }
    ) do |_value|
      calls += 1
      raise ArgumentError
    end

    expect(steps).to eq(2)
    expect(calls).to eq(2)
    expect(status[:candidate_budget_exhausted]).to be(true)
    expect(status[:execution_budget_exhausted]).to be(false)
  end

  it 'stops when the property execution budget is exhausted' do
    children = Enumerator.new { |yielder| (1..).each { |value| yielder << PropCheck::LazyTree.new(value) } }
    tree = PropCheck::LazyTree.new(0, children.lazy)
    calls = 0

    _result, _exception, steps, status = shrink(
      tree,
      ArgumentError.new,
      max_shrink_candidates: 10,
      max_shrink_steps: 2,
      failure_classifier: proc { |error, _input| error.class }
    ) do |_value|
      calls += 1
      raise ArgumentError
    end

    expect(steps).to eq(2)
    expect(calls).to eq(2)
    expect(status[:candidate_budget_exhausted]).to be(false)
    expect(status[:execution_budget_exhausted]).to be(true)
  end

  it 'handles cyclic lazy trees using stable candidate keys' do
    child = PropCheck::LazyTree.new(1)
    root = PropCheck::LazyTree.new(0, [child].lazy)
    child.instance_variable_set(:@children, [root].lazy)

    result, _exception, steps, status = shrink(
      root,
      ArgumentError.new,
      failure_classifier: proc { |error, _input| error.class },
      candidate_key_function: proc { |input| input }
    ) do |value|
      raise ArgumentError if value.zero?
    end

    expect(result).to eq(0)
    expect(steps).to eq(1)
    expect(status).to include(complete: true)
  end
end
