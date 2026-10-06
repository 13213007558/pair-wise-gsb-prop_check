module PropCheck
  class Property
    CoverageReport = Struct.new(:n_successful, :category_counts, :requirements, :requested_runs, :maximum_runs,
                                keyword_init: true) do
      def satisfied?
        requirements.all?(&:met?)
      end

      def conclusive?
        requirements.none?(&:inconclusive?)
      end

      def to_s
        lines = ["Coverage after #{n_successful} successful samples " \
                 "(requested #{requested_runs}, budget #{maximum_runs}):"]
        category_counts.each do |label, count|
          lines << "  #{label.inspect}: #{count}"
        end

        requirements.each do |result|
          lines << "  #{result.label.inspect}: #{result.count}/#{result.applicable_count} " \
                   "(#{(result.lower_bound * 100).round(4)}% lower, " \
                   "#{(result.upper_bound * 100).round(4)}% upper); " \
                   "required >= #{(result.minimum * 100).round(4)}% [#{result.status}]"
        end
        lines.join("\n")
      end
    end

    CoverageResult = Struct.new(:label, :minimum, :confidence, :count, :applicable_count,
                                :lower_bound, :upper_bound, :status, keyword_init: true) do
      def met?
        status == :met
      end

      def below?
        status == :below
      end

      def inconclusive?
        status == :inconclusive
      end
    end

    class CoverageTracker
      Classifier = Struct.new(:labels, :condition)
      Collector = Struct.new(:classifier)
      Requirement = Struct.new(:label, :minimum, :applicable, :condition, :confidence)

      def initialize(classifiers:, collectors:, requirements:)
        @classifiers = classifiers
        @collectors = collectors
        @requirements = requirements
        @counts = Hash.new(0)
        @category_order = []
        @applicable_counts = Array.new(requirements.size, 0)
        @hit_counts = Array.new(requirements.size, 0)

        (classifiers.flat_map(&:labels) + requirements.map(&:label)).uniq.each do |label|
          remember_label(label)
        end
      end

      def record(root)
        labels = labels_for(root)
        labels.uniq.each { |label| remember_label(label); @counts[label] += 1 }

        @requirements.each_with_index do |requirement, index|
          next unless applicable?(requirement, root)

          @applicable_counts[index] += 1
          belongs = if requirement.condition
                      PropCheck::Helper.call_splatted(root, &requirement.condition)
                    else
                      labels.include?(requirement.label)
                    end
          @hit_counts[index] += 1 if belongs
        end
      end

      def report(n_successful, requested_runs, maximum_runs)
        results = @requirements.each_with_index.map do |requirement, index|
          applicable_count = @applicable_counts[index]
          count = @hit_counts[index]
          lower_bound = ExactBinomial.lower_bound(count, applicable_count, requirement.confidence)
          upper_bound = ExactBinomial.upper_bound(count, applicable_count, requirement.confidence)
          status = status_for(requirement.minimum, lower_bound, upper_bound)

          CoverageResult.new(
            label: requirement.label,
            minimum: requirement.minimum,
            confidence: requirement.confidence,
            count: count,
            applicable_count: applicable_count,
            lower_bound: lower_bound,
            upper_bound: upper_bound,
            status: status
          )
        end

        CoverageReport.new(
          n_successful: n_successful,
          category_counts: @category_order.map { |label| [label, @counts[label]] }.to_h,
          requirements: results,
          requested_runs: requested_runs,
          maximum_runs: maximum_runs
        )
      end

      private def labels_for(root)
        classified = @classifiers.flat_map do |classifier|
          next [] unless PropCheck::Helper.call_splatted(root, &classifier.condition)

          classifier.labels
        end
        collected = @collectors.flat_map do |collector|
          Array(PropCheck::Helper.call_splatted(root, &collector.classifier))
        end
        (classified + collected).reject(&:nil?)
      end

      private def applicable?(requirement, root)
        return true if requirement.applicable.nil?

        PropCheck::Helper.call_splatted(root, &requirement.applicable)
      end

      private def remember_label(label)
        return if @category_order.include?(label)

        @category_order << label
        @counts[label] ||= 0
      end

      private def status_for(minimum, lower_bound, upper_bound)
        return :met if lower_bound >= minimum
        return :below if upper_bound < minimum

        :inconclusive
      end
    end

    module ExactBinomial
      module_function

      def lower_bound(successes, trials, confidence)
        return 0.0 if successes.zero? || trials.zero?

        solve_lower(0.0, 1.0, 1 - confidence) do |probability|
          upper_tail(successes, trials, probability)
        end
      end

      def upper_bound(successes, trials, confidence)
        return 1.0 if successes == trials

        solve_upper(0.0, 1.0, 1 - confidence) do |probability|
          lower_tail(successes, trials, probability)
        end
      end

      def solve_lower(low, high, alpha)
        70.times do
          middle = (low + high) / 2.0
          if yield(middle) > alpha
            high = middle
          else
            low = middle
          end
        end
        low
      end

      def solve_upper(low, high, alpha)
        70.times do
          middle = (low + high) / 2.0
          if yield(middle) > alpha
            low = middle
          else
            high = middle
          end
        end
        high
      end

      def upper_tail(successes, trials, probability)
        return 0.0 if probability.zero?
        return 1.0 if probability == 1

        sum_log_probabilities(successes..trials, trials, probability)
      end

      def lower_tail(successes, trials, probability)
        return 1.0 if probability.zero?
        return 0.0 if probability == 1

        sum_log_probabilities(0..successes, trials, probability)
      end

      def sum_log_probabilities(range, trials, probability)
        log_factorial = log_factorials(trials)
        log_probabilities = range.map do |count|
          log_factorial[trials] - log_factorial[count] - log_factorial[trials - count] +
            count * Math.log(probability) + (trials - count) * Math.log(1 - probability)
        end
        maximum = log_probabilities.max
        Math.exp(Math.log(log_probabilities.sum { |value| Math.exp(value - maximum) }) + maximum)
      end

      def log_factorials(trials)
        [0.0].tap do |values|
          (1..trials).each { |count| values << values.last + Math.log(count) }
        end
      end
    end
  end
end
