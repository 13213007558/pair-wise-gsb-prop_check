# frozen_string_literal: true

class PropCheck::Property::ChoiceTapeShrinker
  def initialize(bindings_tree, io, generator, tape, config, problem_exception)
    @best_tree = bindings_tree
    @best_tape = tape
    @generator = generator
    @io = io
    @config = config
    @best_exception = problem_exception
    @candidate_exception = nil
    @shrink_steps = 0
  end

  def self.call(bindings_tree, io, generator, tape, config, problem_exception, &block)
    new(bindings_tree, io, generator, tape, config, problem_exception).call(&block)
  end

  def call(&block)
    @io.puts 'Shrinking...' if @config.verbose

    shrink(&block)

    print_shrinking_exceeded_message if @shrink_steps >= @config.max_shrink_steps

    [@best_tree.root, @best_exception, @shrink_steps, @best_tape]
  end

  private

  def shrink(&block)
    loop do
      @best_tape.choices.each_with_index do |choice, index|
        break if @shrink_steps >= @config.max_shrink_steps

        prefix = @best_tape.choices.first(index).map(&:to_a)
        begin
          _probe_tree, probe_tape = generate_probe(prefix)
        rescue PropCheck::Errors::GeneratorExhaustedError
          next
        end
        actual_choice = probe_tape.choices.fetch(index)

        candidate_values(choice.value, actual_choice).each do |value|
          break if @shrink_steps >= @config.max_shrink_steps

          inc_shrink_step
          candidate_choices = prefix.dup
          candidate_choices << [actual_choice.min, actual_choice.max, value]
          candidate_tape = new_prefix_tape(candidate_choices)
          begin
            candidate_tree = generate(candidate_tape)
          rescue PropCheck::Errors::GeneratorExhaustedError
            next
          end
          @candidate_exception = nil

          if candidate_fails?(candidate_tree, &block)
            accept(candidate_tree, candidate_tape, @candidate_exception)
            return
          end
        end
      end

      break
    end
  end

  def generate_probe(prefix)
    tape = new_prefix_tape(prefix)
    [generate(tape), tape]
  end

  def new_prefix_tape(choices)
    PropCheck::ChoiceTape.new(nil,
                             choices: choices,
                             mode: :prefix,
                             size: @best_tape.size)
  end

  def generate(tape)
    @generator.generate(
      size: tape.size,
      rng: tape,
      choice_tape: tape,
      max_consecutive_attempts: @config.max_consecutive_attempts,
      config: @config
    )
  end

  def candidate_values(current_value, actual_choice)
    min = actual_choice.min
    max = actual_choice.max
    return [] if current_value == min
    return [min] unless (min..max).cover?(current_value)

    values = [min]
    step = current_value - min

    while step > 1
      step = (step / 2.0).truncate
      value = min + step
      values << value unless value <= min || value >= current_value
    end

    values.uniq
  end

  def candidate_fails?(candidate_tree, &block)
    PropCheck::Helper.call_splatted(candidate_tree.root, &block)
    false
  rescue SignalException, SystemExit
    raise
  rescue Exception => e
    @candidate_exception = e
    true
  end

  def accept(tree, tape, exception)
    @best_tree = tree
    @best_tape = tape
    @best_exception = exception
  end

  def inc_shrink_step
    @shrink_steps += 1
    @io.print '.' if @config.verbose
  end

  def print_shrinking_exceeded_message
    @io.puts "(Note: Exceeded #{@config.max_shrink_steps} shrinking steps, the maximum.)"
  end
end
