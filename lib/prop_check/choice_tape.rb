# frozen_string_literal: true

module PropCheck
  class ChoiceTape
    Choice = Struct.new(:min, :max, :value, keyword_init: true) do
      def domain?(other_min, other_max)
        min == other_min && max == other_max
      end

      def to_a
        [min, max, value]
      end
    end

    attr_reader :choices, :size, :depth, :position

    def initialize(random = nil, choices: [], mode: :record, size: nil)
      @random = random
      @mode = mode
      @size = size
      @choices = choices.map { |choice| coerce_choice(choice) }
      @initial_choices = @choices.map(&:dup)
      @choices = [] if mode == :replay
      @logged_choices = mode == :replay ? @initial_choices : []
      @depth = 0
      @position = 0
    end

    def begin_generation
      @depth += 1
    end

    def end_generation
      @depth -= 1 if @depth.positive?
    end

    def top_level_generation?
      @depth == 1
    end

    def rewind_to(position)
      max_position =
        case @mode
        when :prefix
          @choices.length
        else
          @initial_choices.length
        end
      unless position.is_a?(Integer) && position >= 0 && position <= max_position
        raise ArgumentError, 'cannot rewind outside the recorded choice tape'
      end

      @position = position

      case @mode
      when :record
        @choices = @choices.first(position)
      when :prefix
        if position <= @initial_choices.length
          @choices = @initial_choices.first(position)
        else
          prefix_length = @initial_choices.length
          suffix_length = position - prefix_length
          @choices = @choices.first(prefix_length + suffix_length)
        end
      end
    end

    def rand(domain = nil)
      min, max = finite_domain(domain)
      index = @position

      case @mode
      when :record
        value = random_value(min, max)
        @choices << Choice.new(min: min, max: max, value: value)
        @position += 1
        value
      when :replay
        choice = replay_choice(index, min, max)
        @choices << choice
        @position += 1
        choice.value
      when :prefix
        choice = prefix_choice(index, min, max)
        @position += 1
        choice.value
      else
        raise Errors::UserError, "Unknown choice tape mode #{@mode.inspect}"
      end
    end

    def finish!
      if @mode == :replay && @position != @initial_choices.length
        @choices = @initial_choices.first(@position).map(&:dup)
        raise Errors::ChoiceTapeMismatchError,
              "First choice tape divergence after choice #{@position}: " \
              "the generator ended after #{@position} choices, but replay contains " \
              "#{@initial_choices.length}."
      end

      @choices = @initial_choices.map(&:dup) if @mode == :replay
      @logged_choices = @choices.map(&:dup)
      @choices
    end

    def reset!
      @choices = @mode == :replay ? [] : @initial_choices.map(&:dup)
      @position = 0
    end

    def logged_choices
      @logged_choices.map(&:dup)
    end

    private

    def coerce_choice(choice)
      case choice
      when Choice
        choice.dup
      when Array
        min, max, value = choice
        validate_integer!(min, 'minimum')
        validate_integer!(max, 'maximum')
        validate_integer!(value, 'value')
        raise ArgumentError, 'choice minimum cannot be greater than maximum' if min > max
        unless value >= min && value <= max
          raise ArgumentError, 'choice value is outside its domain'
        end

        Choice.new(min: min, max: max, value: value)
      else
        raise ArgumentError, "cannot coerce #{choice.class} into a choice"
      end
    end

    def finite_domain(domain)
      case domain
      when Integer
        raise ArgumentError, "random number count must be positive but got #{domain}" unless domain.positive?

        [0, domain - 1]
      when Range
        min = domain.begin
        max = domain.end
        validate_integer!(min, 'range minimum')
        validate_integer!(max, 'range maximum')
        max -= 1 if domain.exclude_end?
        raise ArgumentError, 'cannot choose from an empty range' if min > max

        [min, max]
      else
        raise Errors::UnreplayableChoiceError,
              'Choice tape can only record finite integer choices, but an unbounded or ' \
              'non-integer random value was requested. Use a generator built on ' \
              'Generators.choose (or another finite integer range) for replayable choices.'
      end
    end

    def validate_integer!(value, name)
      return if value.is_a?(Integer)

      raise ArgumentError, "choice #{name} must be an integer but got #{value.inspect}"
    end

    def random_value(min, max)
      value = @random.rand(min..max)
      unless value.is_a?(Integer) && value >= min && value <= max
        raise Errors::UnreplayableChoiceError,
              'underlying random generator did not return a finite integer choice'
      end

      value
    end

    def replay_choice(index, min, max)
      expected = @initial_choices[index]
      return record_missing_choice(min, max) if expected.nil?
      return expected if expected.domain?(min, max)

      raise Errors::ChoiceTapeMismatchError, domain_mismatch_message(index, expected, min, max)
    end

    def record_missing_choice(min, max)
      message = +"First choice tape divergence at choice #{@initial_choices.length + 1}: "
      message << "replay ended after #{@initial_choices.length} choices, but the generator requested "
      message << "a value from #{format_domain(min, max)}."
      raise Errors::ChoiceTapeMismatchError, message
    end

    def prefix_choice(index, min, max)
      if index < @initial_choices.length
        expected = @initial_choices[index]
        return expected if expected.domain?(min, max)

        raise Errors::ChoiceTapeMismatchError, domain_mismatch_message(index, expected, min, max)
      end

      choice = Choice.new(min: min, max: max, value: min)
      @choices << choice
      choice
    end

    def domain_mismatch_message(index, expected, min, max)
      "First choice tape divergence at choice #{index + 1}: " \
        "expected a value from #{format_domain(expected.min, expected.max)}, " \
        "but the generator requested #{format_domain(min, max)}."
    end

    def format_domain(min, max)
      return "0...#{max + 1}" if min.zero? && max >= 0

      "#{min}..#{max}"
    end
  end
end
