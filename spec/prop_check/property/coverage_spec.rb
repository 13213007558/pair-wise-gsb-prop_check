# frozen_string_literal: true

RSpec.describe PropCheck::Property::Coverage do
  let(:generators) { PropCheck::Generators }

  def fixed_values(values)
    next_index = 0
    PropCheck::Generator.new do
      value = values[next_index % values.length]
      next_index += 1
      PropCheck::LazyTree.wrap(value)
    end
  end

  def fixed_values_with_filters(values)
    next_index = 0
    PropCheck::Generator.new do
      value = values[next_index % values.length]
      next_index += 1
      PropCheck::LazyTree.wrap(value.nil? ? :"_PropCheck.filter_me" : value)
    end
  end

  describe '#classify and #collect' do
    it 'records overlapping categories for each successful sample' do
      generator = fixed_values([0, 1, 4])

      report = PropCheck
               .forall(generator)
               .with_config(n_runs: 6)
               .classify(:even) { |value| value.even? }
               .classify(:small) { |value| value < 5 }
               .check { |value| expect(value).to be_a(Integer) }

      expect(report.sample_count).to eq(6)
      expect(report.category_counts).to eq(even: 4, small: 6)
    end

    it 'collects dynamic categories, arrays, and skips nil' do
      generator = fixed_values([0, 1, 4])

      report = PropCheck
               .forall(generator)
               .with_config(n_runs: 3)
               .collect do |value|
                 case value
                 when 0 then %i[zero even]
                 when 4 then %i[four even]
                 else nil
                 end
               end
               .check {}

      expect(report.category_counts).to eq(zero: 1, even: 2, four: 1)
    end

    it 'does not count filtered values in the successful denominator' do
      accepted = [nil, :a, nil, :b, nil, :a, nil, :a, nil, :b]
      generator = fixed_values_with_filters(accepted)

      report = PropCheck
               .forall(generator)
               .with_config(n_runs: 10, max_generate_attempts: 100)
               .collect { |value| value }
               .check {}

      expect(report.sample_count).to eq(10)
      expect(report.category_counts).to eq(a: 6, b: 4)
    end
  end

  describe '#cover' do
    it 'uses only the applicable category as conditional coverage denominator' do
      values = [
        nil, { group: :a, hit: true },
        nil, { group: :b, hit: false },
        nil, { group: :a, hit: false }
      ]
      generator = fixed_values_with_filters(values)

      report = PropCheck
               .forall(generator)
               .with_config(n_runs: 12, max_generate_attempts: 100)
               .collect do |group:, hit:|
                 [group] + (hit && group == :a ? [:hit_a] : [])
               end
               .cover(:hit_a, 0.15, applicable: :a)
               .check {}

      result = report.results.first
      expect(result[:applicable_count]).to eq(8)
      expect(result[:count]).to eq(4)
      expect(result[:status]).to eq(:satisfied)
      expect(report).to be_coverage_satisfied
    end

    it 'reports inconclusive at a small fixed budget instead of failing the property' do
      generator = fixed_values([true] + [false] * 19)

      report = PropCheck
               .forall(generator)
               .with_config(n_runs: 20)
               .cover(:rare, 0.1) { |value| value }
               .check {}

      expect(report.sample_count).to eq(20)
      expect(report.results.first[:count]).to eq(1)
      expect(report.results.first[:status]).to eq(:inconclusive)
      expect(report).to be_coverage_inconclusive
      expect(report.budget_reached?).to be(true)
    end

    it 'detects a narrow generator when the maximum budget confidently rules coverage out' do
      all_assertions_ran = 0

      expect do
        PropCheck
          .forall(value: generators.constant(0))
          .with_config(n_runs: 100)
          .cover(:positive, 0.1) { |value:| value.positive? }
          .check do |value:|
            all_assertions_ran += 1
            expect(value).to be_a(Integer)
          end
      end.to raise_error(PropCheck::Errors::CoverageViolationError) do |error|
        report = error.coverage_report
        expect(report.sample_count).to eq(100)
        expect(report.results.first[:applicable_count]).to eq(100)
        expect(report.results.first[:count]).to eq(0)
        expect(report.results.first[:status]).to eq(:violated)
      end

      expect(all_assertions_ran).to eq(100)
    end

    it 'treats no applicable samples as inconclusive rather than violated' do
      report = PropCheck
               .forall(value: generators.constant(0))
               .with_config(n_runs: 10)
               .cover(:positive, 0.1, applicable: ->(value:) { value.positive? })
               .check {}

      expect(report.results.first[:applicable_count]).to eq(0)
      expect(report.results.first[:status]).to eq(:inconclusive)
      expect(report).to be_coverage_inconclusive
    end

    it 'rejects minimum proportions outside 0..1' do
      expect do
        PropCheck.forall(generators.integer).cover(:odd, 1.2)
      end.to raise_error(ArgumentError, /between 0 and 1/)
    end
  end

  describe PropCheck::Property::Coverage::Statistic do
    it 'uses fixed sample counts and exact one-sided binomial boundaries' do
      statistic = described_class

      expect(statistic.assess(0, 20, 0.10, 0.95)[:status]).to eq(:violated)
      expect(statistic.assess(4, 20, 0.10, 0.95)[:status]).to eq(:inconclusive)
      expect(statistic.assess(20, 20, 0.80, 0.95)[:status]).to eq(:satisfied)
      expect(statistic.assess(20, 20, 0.95, 0.95)[:status]).to eq(:inconclusive)
    end

    it 'rejects invalid configured confidence levels' do
      property = PropCheck
                 .forall(generators.integer)
                 .with_config(n_runs: 1, coverage_confidence: 1)

      expect { property.check {} }.to raise_error(ArgumentError, /coverage_confidence/)
    end
  end

  describe 'shrinking' do
    it 'does not include repeated shrink executions in coverage statistics' do
      attempt = 0
      generator = PropCheck::Generator.new do
        attempt += 1
        if attempt == 1
          PropCheck::LazyTree.wrap(0)
        else
          PropCheck::LazyTree.new(10, [PropCheck::LazyTree.wrap(0)].lazy)
        end
      end
      classifier_calls = 0
      property_calls = 0

      expect do
        PropCheck
          .forall(generator)
          .with_config(n_runs: 2)
          .classify(:nonnegative) do |value|
            classifier_calls += 1
            value >= 0
          end
          .check do |value|
            property_calls += 1
            raise 'found narrow counterexample' if value >= 10
          end
      end.to raise_error(RuntimeError, /narrow counterexample/)

      expect(property_calls).to eq(3)
      expect(classifier_calls).to eq(1)
    end
  end
end
