# frozen_string_literal: true

RSpec.describe PropCheck::Generators, '#function' do
  include described_class

  let(:return_generator) { integer }

  def generate_function(generator = function(return_generator), rng: Random.new(42), **options)
    generator.call(rng: rng, size: 10, **options)
  end

  def function_with_same_seed(generated_function, return_generator)
    PropCheck::GeneratedFunction.new(
      PropCheck::GeneratedFunction::DEFAULT_KEY_FUNCTION,
      return_generator,
      { size: 10, max_consecutive_attempts: 100 },
      generated_function.base_seed
    )
  end

  it 'generates a callable value' do
    expect(generate_function).to respond_to(:call)
  end

  it 'returns the same output for repeated calls with the same argument' do
    generated_function = generate_function

    first = generated_function.call(1)
    second = generated_function.call(1)
    third = generated_function.call(1)

    expect(second).to eq(first)
    expect(third).to eq(first)
  end

  it 'keeps separate random branches for different arguments' do
    generated_function = generate_function(function(choose(0...1_000_000)), rng: Random.new(123))
    observed = 50.times.map { |argument| generated_function.call(argument) }

    expect(observed.uniq.length).to be > 10
    expect(50.times.map { |argument| generated_function.call(argument) }).to eq(observed)
  end

  it 'does not let call order change pointwise results' do
    PropCheck.forall(
      seed: choose(1..1_000_000),
      first_inputs: array(integer, min: 1, max: 8),
      second_inputs: array(integer, min: 1, max: 8)
    ) do |seed:, first_inputs:, second_inputs:|
      left_function = function(integer).call(rng: Random.new(seed), size: 10)
      right_function = function(integer).call(rng: Random.new(seed), size: 10)

      left = (first_inputs + second_inputs).map { |argument| [argument, left_function.call(argument)] }.to_h
      right = (second_inputs + first_inputs).map { |argument| [argument, right_function.call(argument)] }.to_h

      expect(left).to eq(right)
    end
  end

  it 'does not let calls to another generated function change results' do
    first_function = generate_function
    second_function = generate_function(rng: Random.new(99))

    first_result = first_function.call(123)
    second_function.call(123)
    second_function.call(456)

    expect(first_function.call(123)).to eq(first_result)
  end

  it 'supports multiple positional arguments through the default key' do
    generated_function = generate_function

    expect(generated_function.call(1, 2)).to eq(generated_function.call(1, 2))
    expect(generated_function.call_table.last[:argument]).to eq([1, 2])
  end

  it 'uses the custom key function to decide argument collisions' do
    generated_function = generate_function(function(proc { |number| number % 2 }, integer))

    odd_result = generated_function.call(1)

    expect(generated_function.call(3)).to eq(odd_result)
    expect(generated_function.call_table).to contain_exactly(
      include(argument: 1, key: 1, output: odd_result),
      include(argument: 3, key: 1, output: odd_result)
    )
  end

  it 'accepts the key function as a keyword argument' do
    generated_function = generate_function(
      function(return_generator: integer, key_function: proc { |number| number % 2 })
    )

    expect(generated_function.call(4)).to eq(generated_function.call(8))
  end

  it 'accepts a value generator keyword and a return generator first with a key keyword' do
    first_function = generate_function(function(value_generator: integer, key: proc { |number| number % 3 }))
    second_function = generate_function(function(integer, key: proc { |number| number % 3 }))

    expect(first_function.call(1)).to eq(first_function.call(4))
    expect(second_function.call(2)).to eq(second_function.call(5))
  end

  it 'asks for a custom key when the default argument cannot be stably encoded' do
    generated_function = generate_function

    expect { generated_function.call(Object.new) }.to raise_error(
      ArgumentError,
      /Pass a custom key function to Generators.function/
    )
  end

  it 'asks for a custom key for recursive values' do
    generated_function = generate_function
    recursive_value = []
    recursive_value << recursive_value

    expect { generated_function.call(recursive_value) }.to raise_error(
      ArgumentError,
      /Pass a custom key function to Generators.function/
    )
  end

  it 'asks for a stable custom key when the key result cannot be encoded' do
    generated_function = generate_function(function(proc { |_number| Object.new }, integer))

    expect { generated_function.call(1) }.to raise_error(
      ArgumentError,
      /custom key function.*cannot be stably encoded/m
    )
  end

  it 'records observed argument/output pairs in the failure call table' do
    generated_function = generate_function
    generated_function.call(:alpha)
    generated_function.call(:beta)

    expect(generated_function.inspect).to include('size: 10', 'base_seed:')
    expect(generated_function.inspect).to include(':alpha')
    expect(generated_function.inspect).to include(':beta')
    expect(generated_function.call_table.map { |entry| entry[:argument] }).to eq(%i[alpha beta])
  end

  it 'shrinks observed outputs while retaining deterministic behavior for unobserved inputs' do
    rng = Random.new(7)
    generator = function(nonnegative_integer)

    tree = loop do
      candidate = generator.generate(rng: rng, size: 10)
      candidate.root.call(42)
      break candidate if candidate.root.call_table.first.fetch(:output) > 0
    end

    original_function = tree.root
    shrunken_function = tree.children.first.root
    unobserved_before_shrinking = function_with_same_seed(shrunken_function, nonnegative_integer)

    expect(shrunken_function.call(42)).to eq(0)
    expect(shrunken_function.call_table.first).to include(argument: 42, output: 0)
    expect(shrunken_function.call(99)).to eq(unobserved_before_shrinking.call(99))
    expect(original_function.call(42)).to eq(original_function.call_table.first.fetch(:output))
  end

  it 'shrinks a failing generated function and prints enough calls to reproduce it' do
    error = nil

    begin
      property = PropCheck.forall(generated_function: function(nonnegative_integer))
      property.with_config(n_runs: 20) do |generated_function:|
        raise 'unexpected generated value' unless generated_function.call(:shrunk).zero?
      end
    rescue => caught_error
      error = caught_error
    end

    expect(error).to be_a(RuntimeError)
    expect(error.message).to include('base_seed:')
    expect(error.message).to match(/argument: :shrunk.*output: 1/m)
    expect(error.prop_check_info[:shrunken_input].fetch(:generated_function).call(99)).to eq(
      error.prop_check_info[:shrunken_input].fetch(:generated_function).call(99)
    )
  end
end
