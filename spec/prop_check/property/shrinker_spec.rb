require 'prop_check/lazy_tree'

RSpec.describe PropCheck::Property::Shrinker do
  BusinessFailure = Class.new(StandardError)
  OtherFailure = Class.new(StandardError)

  def shrink(tree, config, &block)
    config = PropCheck::Property::Configuration.new(**config) if config.is_a?(Hash)
    described_class.call(
      tree,
      StringIO.new,
      PropCheck::Hooks.new,
      config,
      BusinessFailure.new('original assertion'),
      &block
    )
  end

  it 'only accepts candidates whose failure category matches the original failure' do
    wrong = PropCheck::LazyTree.new(m: 10, n: 0)
    target = PropCheck::LazyTree.new(m: 0, n: 1)
    root = PropCheck::LazyTree.new({ m: 11, n: 1 }, [wrong, target])
    executed = []

    result, exception, steps = shrink(
      root,
      failure_classifier: ->(error) { error.is_a?(BusinessFailure) ? :assertion : :other },
      complexity_function: ->(value) { value[:m] },
      candidate_key_function: ->(value) { [value[:m], value[:n]] }
    ) do |value|
      executed << value
      raise OtherFailure, 'zero division' if value[:n].zero?
      raise BusinessFailure, 'business assertion' if value[:m] >= 0
    end

    expect(result).to eq(m: 0, n: 1)
    expect(exception).to be_a(BusinessFailure)
    expect(executed).to eq([
      { m: 0, n: 1 },
      { m: 10, n: 0 }
    ])
    expect(steps).to eq(2)
  end

  it 'traverses an earlier different-exception branch during depth-first search without accepting it' do
    wrong_target = PropCheck::LazyTree.new(m: 0, n: 1)
    wrong = PropCheck::LazyTree.new({ m: 10, n: 0 }, [wrong_target])
    root = PropCheck::LazyTree.new({ m: 11, n: 1 }, [wrong])
    executed = []

    result, exception, steps = shrink(
      root,
      failure_classifier: ->(error) { error.is_a?(BusinessFailure) ? :assertion : :other },
      candidate_key_function: ->(value) { [value[:m], value[:n]] }
    ) do |value|
      executed << value
      raise OtherFailure, 'zero division' if value[:n].zero?
      raise BusinessFailure, 'business assertion' if value[:m] >= 0
    end

    expect(executed).to eq([
      { m: 10, n: 0 },
      { m: 0, n: 1 }
    ])
    expect(result).to eq(m: 0, n: 1)
    expect(exception).to be_a(BusinessFailure)
    expect(exception.message).to eq('business assertion')
    expect(steps).to eq(2)
  end

  it 'de-duplicates candidates by caller-provided stable keys, including cyclic trees' do
    small = PropCheck::LazyTree.new(1)
    large = PropCheck::LazyTree.new(2, [small])
    small.instance_variable_set(:@children, [large].lazy)

    result, exception, steps = shrink(
      large,
      candidate_key_function: ->(value) { value }
    ) do |value|
      raise BusinessFailure if value.positive?
    end

    expect(result).to eq(1)
    expect(exception).to be_a(BusinessFailure)
    expect(steps).to eq(1)
  end

  it 'limits candidate generation independently from property executions' do
    children = [0, 1, 2].map { |value| PropCheck::LazyTree.new(value) }.lazy
    root = PropCheck::LazyTree.new(10, children)

    result, _exception, steps, status = shrink(
      root,
      max_shrink_candidates: 3,
      max_shrink_steps: 10
    ) { }

    expect(result).to eq(10)
    expect(steps).to eq(3)
    expect(status).to eq(:candidate_budget_exhausted)
  end

  it 'limits property executions without generating the rest of a wide branch' do
    children = (0..).lazy.map { |value| PropCheck::LazyTree.new(value) }
    root = PropCheck::LazyTree.new(10, children)

    result, _exception, steps, status = shrink(
      root,
      max_shrink_candidates: 10,
      max_shrink_steps: 2
    ) { }

    expect(result).to eq(10)
    expect(steps).to eq(2)
    expect(status).to eq(:property_budget_exhausted)
  end
end
