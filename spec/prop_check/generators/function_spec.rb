# frozen_string_literal: true

RSpec.describe PropCheck::Generators, '#function' do
  subject(:generators) { described_class }

  def generate_function(generator, **kwargs)
    options = { rng: Random.new(42), size: 10 }.merge(kwargs)
    generator.call(**options)
  end

  it 'generates a callable deterministic value' do
    fun = generate_function(generators.function(generators.choose(0...1_000_000)))

    expect(fun.call(3)).to eq(fun.call(3))
  end

  it 'accepts the key function before or after the return-value generator' do
    key = ->(argument) { argument % 2 }
    first = generate_function(generators.function(key, generators.integer))
    second = generate_function(generators.function(generators.integer, key))

    expect(first.call(1)).to eq(first.call(3))
    expect(second.call(2)).to eq(second.call(4))
  end

  it 'rejects ambiguous generator and key-function arguments' do
    expect { generators.function(generators.integer, generators.integer) }
      .to raise_error(ArgumentError, /return-value generator and an optional key function/)
  end

  it 'gives different arguments independent branches' do
    fun = generate_function(generators.function(generators.choose(0...1_000_000)))

    expect(fun.call(1)).not_to eq(fun.call(2))
  end

  it 'is unaffected by call order, repeated calls, and another generated function' do
    rng_a = Random.new(123)
    rng_b = Random.new(123)
    generator = generators.function(generators.choose(0...1_000_000_000))

    first = generator.call(rng: rng_a, size: 20)
    second = generator.call(rng: rng_b, size: 20)
    other = generator.call(rng: rng_b, size: 20)

    first_inputs = [1, 2, 3, 4]
    second_inputs = [4, 3, 2, 1]

    first_table = first_inputs.map do |input|
      other.call(100 + input)
      [input, first.call(input)]
    end.to_h

    second_table = second_inputs.map do |input|
      [input, second.call(input)]
    end.to_h

    expect(second_table).to eq(first_table)
  end

  it 'documents custom-key collisions by sharing one branch' do
    generator = generators.function(
      generators.choose(0...1_000_000),
      key: ->(argument) { argument % 2 }
    )
    fun = generate_function(generator)

    expect(fun.call(1)).to eq(fun.call(3))
    expect(fun.observed_calls.map(&:first)).to contain_exactly(1, 3)
  end

  it 'treats equal hashes with different insertion orders as one key' do
    fun = generate_function(generators.function(generators.choose(0...1_000_000)))
    first = { a: 1, b: 2 }
    second = { b: 2, a: 1 }

    expect(fun.call(first)).to eq(fun.call(second))
    expect(fun.observed_calls.map(&:first)).to contain_exactly(first, second)
  end

  it 'treats positive and negative zero floats as one key' do
    fun = generate_function(generators.function(generators.choose(0...1_000_000)))

    expect(fun.call(0.0)).to eq(fun.call(-0.0))
  end

  it 'supports generated functions as return values' do
    nested = generators.function(generators.function(generators.choose(0...1_000_000)))
    fun = generate_function(nested)
    returned = fun.call(1)

    expect(returned.call(2)).to eq(returned.call(2))
  end

  it 'records repeated calls once in the observed call table' do
    fun = generate_function(generators.function(generators.choose(0...1_000_000)))

    2.times { expect(fun.call(5)).to eq(fun.call(5)) }

    expect(fun.observed_calls).to contain_exactly([5, fun.call(5)])
  end

  it 'requires a custom stable key for unsupported default argument types' do
    unsupported = Object.new
    fun = generate_function(generators.function(generators.integer))

    expect { fun.call(unsupported) }.to raise_error(
      ArgumentError,
      /Pass `function\(\.\.\., key:/m
    )
  end

  it 'requires custom keys that can be stably serialized' do
    generator = generators.function(
      generators.integer,
      key: ->(_argument) { proc {} }
    )
    fun = generate_function(generator)

    expect { fun.call(1) }.to raise_error(
      ArgumentError,
      /stably serializable with Marshal.*custom `key:`/m
    )
  end

  it 'shrinks observed argument/result pairs while retaining unobserved deterministic behavior' do
    generator = generators.function(generators.choose(4..100))
    root = generator.generate(rng: Random.new(77), size: 10)
    root.root.call(4)
    root.root.call(9)

    property = proc do |fun|
      fails = fun.call(4) >= 4 || fun.call(9) >= 4
      raise 'failure' if fails
    end

    shrunken, exception, = PropCheck::Property::Shrinker.call(
      root,
      StringIO.new,
      PropCheck::Hooks.new,
      PropCheck::Property::Configuration.new,
      &property
    )

    expect(exception.message).to eq('failure')
    expect([shrunken.call(4), shrunken.call(9)]).to eq([4, 0]).or eq([0, 4])

    control = generator.call(rng: Random.new(77), size: 10)
    unobserved_result = control.call(123)

    expect(shrunken.call(123)).to eq(unobserved_result)
    expect(shrunken.seed).to eq(control.seed)
  end

  it 'includes an observed call table in failure output' do
    status = nil
    first_inputs = [7, 8]
    second_inputs = [-2, -3]

    begin
      PropCheck.forall(generators.function(generators.choose(4..100)))
              .with_config(n_runs: 1) do |fun|
        first_result = first_inputs.map { |input| [input, fun.call(input)] }.to_h
        second_result = second_inputs.map { |input| [input, fun.call(input)] }.to_h

        observed = second_result.merge(first_result)
        raise 'map composition failure' if observed.values.any? { |value| value < 100 }
      end
    rescue RSpec::Expectations::ExpectationNotMetError
      raise
    rescue StandardError => error
      status = error
    end

    expect(status.message).to include(
      'call table:',
      '7 =>',
      '8 =>',
      '-2 =>',
      '-3 =>',
      'map composition failure'
    )
  end

  it 'demonstrates the map composition law regardless of input-group call order' do
    rng_a = Random.new(2026)
    rng_b = Random.new(2026)
    generator = generators.function(generators.choose(0...1_000_000))
    left = generator.call(rng: rng_a, size: 20)
    right = generator.call(rng: rng_b, size: 20)
    other = generators.function(generators.choose(0...1_000_000)).call(
      rng: Random.new(999),
      size: 20
    )

    first_inputs = [10, 20, 30]
    second_inputs = [40, 50, 60]

    first_result = (first_inputs + second_inputs).map do |input|
      other.call(input)
      [input, left.call(input)]
    end.to_h

    second_result = (second_inputs + first_inputs).map do |input|
      [input, right.call(input)]
    end.to_h

    expect(second_result).to eq(first_result)
  end
end
