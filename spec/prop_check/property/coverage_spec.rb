require 'prop_check/lazy_tree'

RSpec.describe PropCheck::Property do
  def fixed_value_generator(values)
    sequence = values.cycle
    PropCheck::Generator.new do
      PropCheck::LazyTree.wrap(sequence.next)
    end
  end

  describe '#classify and #collect' do
    it 'records fixed labels only for successful, unfiltered samples' do
      generator = fixed_value_generator(%w[keep drop keep]).where { |value| value == 'keep' }
      seen = []

      report = described_class.forall(generator)
                         .with_config(n_runs: 2, max_generate_attempts: 5, max_consecutive_attempts: 5)
                         .classify(:kept) { true }
                         .check { |value| seen << value }

      expect(seen).to eq(%w[keep keep])
      expect(report.n_successful).to eq(2)
      expect(report.category_counts).to eq(kept: 2)
      expect(report.requirements).to be_empty
    end

    it 'allows one successful sample to belong to multiple categories' do
      generator = fixed_value_generator([{ parity: :even, multiple_of_three: false },
                                         { parity: :odd, multiple_of_three: true },
                                         { parity: :even, multiple_of_three: true }])

      report = described_class.forall(generator)
                         .with_config(n_runs: 3)
                         .classify(:even) { |value| value[:parity] == :even }
                         .classify(:multiple_of_three) { |value| value[:multiple_of_three] }
                         .collect { |value| value[:parity] }
                         .check { }

      expect(report.category_counts).to eq(even: 2, multiple_of_three: 2, :odd => 1)
    end

    it 'classifies every successful sample when no condition is given' do
      report = described_class.forall(fixed_value_generator([1, 2]))
                         .with_config(n_runs: 2)
                         .classify(:fixed)
                         .check { }

      expect(report.category_counts).to eq(fixed: 2)
    end

    it 'keeps coverage declarations when later filtering or changing configuration' do
      generator = fixed_value_generator([1, 2, 3, 4])

      report = described_class.forall(generator)
                         .classify(:even) { |value| value.even? }
                         .where { |value| value < 4 }
                         .with_config(n_runs: 3)
                         .check { }

      expect(report.n_successful).to eq(3)
      expect(report.category_counts).to eq(even: 1)
    end
  end

  describe '#cover' do
    it 'uses the requirement-specific applicable sample count as the denominator' do
      values = [
        { group: :a, valid: true },
        { group: :b, valid: true },
        { group: :a, valid: false },
        { group: :b, valid: false }
      ]

      report = described_class.forall(fixed_value_generator(values))
                         .with_config(n_runs: 4, max_coverage_runs: 4)
                         .cover(:valid_a, 0.5, applicable: ->(value) { value[:group] == :a }) do |value|
                           value[:valid]
                         end
                         .check { }

      result = report.requirements.fetch(0)
      expect(result.applicable_count).to eq(2)
      expect(result.count).to eq(1)
      expect(result).to be_inconclusive
    end

    it 'is inconclusive when a conditional denominator has no applicable samples' do
      report = described_class.forall(x: PropCheck::Generators.positive_integer)
                         .with_config(n_runs: 3, max_coverage_runs: 3)
                         .cover(:zero, 0.1, applicable: ->(x:) { x.zero? }) { true }
                         .check { }

      result = report.requirements.fetch(0)
      expect(result.applicable_count).to eq(0)
      expect(result).to be_inconclusive
    end

    it 'treats too little evidence as inconclusive rather than failing the property' do
      report = described_class.forall(fixed_value_generator([:rare, :common, :common, :common]))
                         .with_config(n_runs: 4, max_coverage_runs: 4)
                         .classify(:rare) { |value| value == :rare }
                         .cover(:rare, 0.4)
                         .check { }

      expect(report.satisfied?).to be(false)
      expect(report.conclusive?).to be(false)
      expect(report.requirements.fetch(0)).to be_inconclusive
    end

    it 'fails coverage when a narrow distribution passes every ordinary assertion' do
      generator = fixed_value_generator([:small] * 100)
      ordinary_assertions = 0

      expect do
        described_class.forall(generator)
                   .with_config(n_runs: 100, max_coverage_runs: 100,
                               max_generate_attempts: 100, max_consecutive_attempts: 100)
                   .classify(:small) { true }
                   .classify(:large) { false }
                   .cover(:large, 0.1)
                   .check do |value|
                     ordinary_assertions += 1
                     expect(value).to eq(:small)
                   end
      end.to raise_error(PropCheck::Errors::CoverageNotMetError) do |error|
        report = error.coverage_report
        expect(report.category_counts).to eq(small: 100, large: 0)
        expect(report.n_successful).to eq(100)
        expect(report.satisfied?).to be(false)
        expect(report.requirements.fetch(0)).to be_below
      end

      expect(ordinary_assertions).to eq(100)
    end

    it 'uses fixed category sequences for the zero-hit exact-coverage boundary' do
      report = described_class.forall(fixed_value_generator([:other] * 28))
                         .with_config(n_runs: 28, max_coverage_runs: 28)
                         .cover(:target, 0.1)
                         .check { }

      expect(report.requirements.fetch(0)).to be_inconclusive

      expect do
        described_class.forall(fixed_value_generator([:other] * 29))
                   .with_config(n_runs: 29, max_coverage_runs: 29)
                   .cover(:target, 0.1)
                   .check { }
      end.to raise_error(PropCheck::Errors::CoverageNotMetError) do |error|
        expect(error.coverage_report.requirements.fetch(0)).to be_below
      end
    end

    it 'uses the maximum budget for coverage requirements' do
      expect do
        described_class.forall(fixed_value_generator([:other] * 200))
                   .with_config(n_runs: 50, max_coverage_runs: 200,
                               max_generate_attempts: 200, max_consecutive_attempts: 200)
                   .cover(:target, 0.1)
                   .check { }
      end.to raise_error(PropCheck::Errors::CoverageNotMetError) do |error|
        report = error.coverage_report
        expect(report.n_successful).to eq(200)
        expect(report.maximum_runs).to eq(200)
      end
    end

    it 'does not count repeated executions during shrinking' do
      values = [
        { shrink: false, valid: true },
        { shrink: false, valid: true },
        { shrink: true, valid: false }
      ].cycle
      generator = PropCheck::Generator.new do
        value = values.next
        PropCheck::LazyTree.new(value, [PropCheck::LazyTree.wrap(value.merge(shrink: true, valid: false))])
      end
      classifications = 0

      expect do
        described_class.forall(generator)
                 .with_config(n_runs: 3)
                 .classify(:valid) do |value|
                   classifications += 1
                   value[:valid]
                 end
                 .check { |value| expect(value[:valid]).to be(true) }
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError)

      expect(classifications).to eq(2)
    end
  end

  describe PropCheck::Property::ExactBinomial do
    it 'computes the Clopper-Pearson boundary for zero successes' do
      aggregate_failures do
        expect(described_class.upper_bound(0, 28, 0.95)).to be >= 0.1
        expect(described_class.upper_bound(0, 29, 0.95)).to be < 0.1
      end
    end
  end
end
