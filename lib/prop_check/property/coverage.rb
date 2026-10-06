# frozen_string_literal: true

module PropCheck
  class Property
    module Coverage
      Classifier = Struct.new(:label, :block, keyword_init: true)
      Rule = Struct.new(:label, :minimum, :applicable, :hit, keyword_init: true)

      class Recorder
        attr_reader :category_counts, :sample_count

        def initialize(classifiers, rules)
          @classifiers = classifiers
          @rules = rules
          @category_counts = Hash.new(0)
          @applicable_counts = Hash.new(0)
          @hit_counts = Hash.new(0)
          @sample_count = 0
        end

        def record(input, &property_block)
          result = property_block.call(input)

          labels = @classifiers.flat_map do |classifier|
            value = PropCheck::Helper.call_splatted(input, &classifier.block)
            value = value ? classifier.label : nil if classifier.label
            Array(value)
          end
          present = labels.compact.uniq
          present.each { |label| @category_counts[label] += 1 }

          @rules.each do |rule|
            next unless applies?(rule, input, present)

            @applicable_counts[rule] += 1
            @hit_counts[rule] += 1 if hits?(rule, input, present)
          end

          @sample_count += 1
          result
        end

        def report(confidence, budget)
          results = @rules.map do |rule|
            applicable_count = @applicable_counts[rule]
            hit_count = @hit_counts[rule]
            assessment = Statistic.assess(
              hit_count,
              applicable_count,
              rule.minimum,
              confidence
            )

            {
              label: rule.label,
              minimum: rule.minimum,
              applicable_count: applicable_count,
              count: hit_count,
              ratio: applicable_count.zero? ? nil : hit_count.to_f / applicable_count,
            }.merge(assessment)
          end

          Report.new(
            sample_count: @sample_count,
            category_counts: @category_counts.dup,
            results: results,
            confidence: confidence,
            budget: budget
          )
        end

        private

        def applies?(rule, input, present)
          predicate = rule.applicable
          return true if predicate.nil?
          return present.include?(predicate) unless predicate.respond_to?(:call)

          PropCheck::Helper.call_splatted(input, &predicate)
        end

        def hits?(rule, input, present)
          predicate = rule.hit
          return present.include?(rule.label) if predicate.nil?

          PropCheck::Helper.call_splatted(input, &predicate)
        end
      end

      class Report
        attr_reader :sample_count, :category_counts, :results, :confidence, :budget

        def initialize(sample_count:, category_counts:, results:, confidence:, budget:)
          @sample_count = sample_count
          @category_counts = category_counts
          @results = results
          @confidence = confidence
          @budget = budget
        end

        def coverage_status
          return :satisfied if @results.empty?
          return :violated if @results.any? { |result| result[:status] == :violated }
          return :satisfied if @results.all? { |result| result[:status] == :satisfied }

          :inconclusive
        end

        def coverage_satisfied?
          coverage_status == :satisfied
        end

        def coverage_inconclusive?
          coverage_status == :inconclusive
        end

        def coverage_violated?
          coverage_status == :violated
        end

        def budget_reached?
          @sample_count == @budget
        end

        def to_h
          {
            sample_count: sample_count,
            category_counts: category_counts.dup,
            results: results.map(&:dup),
            confidence: confidence,
            budget: budget
          }
        end

        def to_s
          lines = ["Coverage after #{sample_count}/#{budget} successful samples:"]
          category_counts.each do |label, count|
            lines << "  #{label.inspect}: #{count}/#{sample_count}"
          end

          results.each do |result|
            applicable = result[:applicable_count]
            count = result[:count]
            minimum = format_ratio(result[:minimum])
            observed = result[:ratio].nil? ? 'n/a' : format_ratio(result[:ratio])
            lines << "  #{result[:label].inspect}: #{count}/#{applicable} " \
              "(observed #{observed}, required #{minimum}, #{result[:status]})"
          end
          lines.join("\n")
        end

        private

        def format_ratio(value)
          format('%.2f%%', value * 100)
        end
      end

      module Statistic
        module_function

        def assess(hit_count, applicable_count, minimum, confidence)
          return assessment(:satisfied, nil, nil) if minimum.zero?
          return assessment(:inconclusive, nil, nil) if applicable_count.zero?

          alpha = 1.0 - confidence
          lower = clopper_pearson_lower(hit_count, applicable_count, alpha)
          upper = clopper_pearson_upper(hit_count, applicable_count, alpha)

          status = :inconclusive
          status = :satisfied if lower >= minimum
          status = :violated if upper < minimum

          assessment(status, lower, upper)
        end

        def assessment(status, lower, upper)
          {
            status: status,
            lower_confidence_bound: lower,
            upper_confidence_bound: upper
          }
        end

        def clopper_pearson_lower(successes, trials, alpha)
          return 0.0 if successes.zero?

          beta_quantile(alpha, successes, trials - successes + 1)
        end

        def clopper_pearson_upper(successes, trials, alpha)
          return 1.0 if successes == trials

          beta_quantile(1.0 - alpha, successes + 1, trials - successes)
        end

        def beta_quantile(probability, alpha, beta)
          low = 0.0
          high = 1.0

          80.times do
            middle = (low + high) / 2.0
            if beta_cdf(middle, alpha, beta) < probability
              low = middle
            else
              high = middle
            end
          end

          (low + high) / 2.0
        end

        def beta_cdf(value, alpha, beta)
          return 0.0 if value <= 0.0
          return 1.0 if value >= 1.0

          alpha = alpha.to_f
          beta = beta.to_f

          prefix = Math.exp(
            alpha * Math.log(value) +
            beta * Math.log(1.0 - value) -
            log_beta(alpha, beta)
          )

          if value < (alpha + 1.0) / (alpha + beta + 2.0)
            prefix * beta_continued_fraction(value, alpha, beta) / alpha
          else
            1.0 - (prefix * beta_continued_fraction(value, beta, alpha) / beta)
          end
        end

        def log_beta(alpha, beta)
          Math.lgamma(alpha).first +
            Math.lgamma(beta).first -
            Math.lgamma(alpha + beta).first
        end

        def beta_continued_fraction(value, alpha, beta)
          alpha_plus_beta = alpha + beta
          alpha_plus_one = alpha + 1.0
          alpha_minus_one = alpha - 1.0
          coefficient = 1.0
          denominator = sanitize_continued_fraction(
            1.0 - alpha_plus_beta * value / alpha_plus_one
          )
          denominator = 1.0 / denominator
          result = denominator

          1.upto(200) do |iteration|
            two_iterations = 2 * iteration
            term = iteration.to_f * (beta - iteration) * value /
              ((alpha_minus_one + two_iterations) * (alpha + two_iterations))
            denominator = sanitize_continued_fraction(1.0 + term * denominator)
            coefficient = sanitize_continued_fraction(1.0 + term / coefficient)
            denominator = 1.0 / denominator
            result *= denominator * coefficient

            term = -(alpha + iteration).to_f * (alpha_plus_beta + iteration) * value /
              ((alpha + two_iterations) * (alpha_plus_one + two_iterations))
            denominator = sanitize_continued_fraction(1.0 + term * denominator)
            coefficient = sanitize_continued_fraction(1.0 + term / coefficient)
            denominator = 1.0 / denominator
            result *= denominator * coefficient
          end

          result
        end

        def sanitize_continued_fraction(value)
          return 1e-300 if value.abs < 1e-300 && value >= 0
          return -1e-300 if value.abs < 1e-300

          value
        end
      end
    end
  end
end
