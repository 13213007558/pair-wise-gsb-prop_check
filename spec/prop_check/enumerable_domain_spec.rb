require 'spec_helper'

RSpec.describe PropCheck::Generator::EnumerableDomain do
  include PropCheck::Generators

  it 'enumerates booleans as a complete finite domain' do
    domain = boolean.enumerable_domain

    expect(domain.map(&:root).to_a).to eq([false, true])
    expect(domain).to be_exhaustive
  end

  it 'fairly interleaves a small branch with a large dependent branch' do
    generator = choose(0..1).bind do |branch|
      branch.zero? ? boolean : choose(0..99)
    end

    values = generator.enumerable_domain.take(6).map(&:root)

    expect(values).to eq([false, 0, true, 1, 2, 3])
    expect(values).to include(false, true, 0)
  end

  it 'does not mark a domain complete when a bind branch is unknown' do
    generator = boolean.bind do |value|
      value ? integer : constant(:small)
    end

    domain = generator.enumerable_domain
    values = domain.take(2).map(&:root)

    expect(values.first).to eq(:small)
    expect(values.last).to be_a(Integer)
    expect(domain).not_to be_exhaustive
    expect(domain.to_a).not_to be_empty
    expect(domain).not_to be_exhaustive
  end

  it 'propagates enumerable domains through tuples and bounded arrays' do
    tuple_domain = tuple(boolean, choose(0..2)).enumerable_domain
    expect(tuple_domain.map(&:root).to_a).to eq([
      [false, 0], [false, 1], [true, 0], [false, 2], [true, 1], [true, 2]
    ])
    expect(tuple_domain).to be_exhaustive

    array_domain = array(boolean, max: 2).enumerable_domain
    expect(array_domain.map(&:root).to_a).to eq([
      [], [false], [true], [false, false], [false, true], [true, false], [true, true]
    ])
    expect(array_domain).to be_exhaustive

    bounded_array_domain = array(boolean, min: 1, max: 3).enumerable_domain
    expect(bounded_array_domain.map(&:root).map(&:length).max).to eq(3)
    expect(bounded_array_domain.enumerated_count).to eq(2 + 4 + 8)
  end

  it 'deduplicates equivalent mapped values by eql? and hash' do
    generator = choose(0..3).map { |value| value.even? }
    domain = generator.enumerable_domain

    expect(domain.map(&:root).to_a).to eq([true, false])
    expect(domain).to be_exhaustive
  end

  it 'checks a complete enumerable domain before continuing with random values' do
    values = []

    PropCheck.forall(boolean).with_config(n_runs: 5) do |value|
      values << value
    end

    expect(values.first(2)).to eq([false, true])
    expect(values.size).to eq(5)
  end

  it 'continues shrinking using the shrink tree associated with an enumerated failure' do
    exception = nil

    begin
      PropCheck.forall(choose(0..10)).with_config(n_runs: 20) do |value|
        raise 'failure' if value > 8
      end
    rescue RSpec::Expectations::ExpectationNotMetError
      raise
    rescue StandardError => error
      exception = error
    end

    info = exception.prop_check_info
    expect(info[:original_input]).to eq(9)
    expect(info[:shrunken_input]).to eq(9)
  end

  it 'visits known values before ordinary random tests in a partially enumerable domain' do
    domain_class = described_class
    generator = PropCheck::Generator.new(
      enumerable_domain: lambda do |**kwargs|
        domain_class.new([
          PropCheck::LazyTree.wrap(:known),
          domain_class::UNKNOWN
        ], exhaustive: false)
      end
    ) do |**|
      PropCheck::LazyTree.wrap(:random)
    end

    values = []
    PropCheck.forall(generator).with_config(n_runs: 5) do |value|
      values << value
    end

    expect(values).to eq([:known, :random, :random, :random, :random])
  end
end
