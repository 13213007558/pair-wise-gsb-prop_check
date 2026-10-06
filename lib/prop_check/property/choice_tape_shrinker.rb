# frozen_string_literal: true

class PropCheck::Property::ChoiceTapeShrinker
  def initialize(binding_generator, bindings_tree, io, config, original_exception)
    @generator = binding_generator
    @tree = bindings_tree
    @io = io
    @config = config
    @entries = bindings_tree.choice_tape.entries.map(&:dup)
    @original_root = bindings_tree.root
    @original_exception = original_exception
    @problem_exception = nil
    @shrink_steps = 0
  end

  def self.call(binding_generator, bindings_tree, io, config, original_exception, &block)
    new(binding_generator, bindings_tree, io, config, original_exception).call(&block)
  end

  def call(&block)
    @io.puts 'Shrinking choice tape...' if @config.verbose

    found_reduction = shrink(&block)

    print_shrinking_exceeded_message if @shrink_steps >= @config.max_shrink_steps

    tape = PropCheck::ChoiceTape.new(mode: :replay, size: @tree.choice_tape.size, entries: @entries)
    root = found_reduction ? @tree.root : @original_root
    exception = found_reduction ? @problem_exception : @original_exception
    [root, exception, @shrink_steps, tape]
  end

  private def shrink(&block)
    found_reduction = false

    loop do
      accepted = try_next_reduction(&block)
      found_reduction ||= accepted == :accepted
      break unless accepted == :accepted
      break if @shrink_steps >= @config.max_shrink_steps
    end

    found_reduction
  end

  private def try_next_reduction(&block)
    @entries.each_with_index do |_entry, index|
      alternative_values(@entries[index]).each do |value|
        candidate_entries = @entries.map(&:dup)
        candidate_entries[index] = [@entries[index][0], @entries[index][1], value]

        begin
          tree = rerun(candidate_entries)
        rescue PropCheck::Errors::ChoiceTapeError
          next
        end
        next if tree.choice_tape.entries == @entries

        begin
          PropCheck::Helper.call_splatted(tree.root, &block)
        rescue PropCheck::Errors::ChoiceTapeError
          next
        rescue Exception => exception
          @entries = tree.choice_tape.entries.map(&:dup)
          @tree = tree
          @problem_exception = exception
          inc_shrink_step
          return :accepted
        end
      end
    end

    :exhausted
  end

  private def alternative_values(entry)
    min, max, value = entry
    return [] if value.zero?

    values = []
    values << 0 if min <= 0 && max >= 0
    values << min if min >= 0
    if value.negative?
      (-1).downto([min, value + 1].max) { |next_value| values << next_value }
    else
      current = value.abs
      while current != 0
        next_value = value - current
        values << next_value if next_value >= min && next_value <= max && !values.include?(next_value)
        current = (current / 2.0).truncate
      end
    end

    values.uniq.reject { |candidate| candidate == value }
  end

  private def rerun(entries)
    tape = PropCheck::ChoiceTape.adapt(
      'size' => @tree.choice_tape.size,
      'choices' => entries
    )
    tree = @generator.generate(
      size: tape.size,
      rng: tape,
      max_consecutive_attempts: @config.max_consecutive_attempts,
      config: @config
    )
    tape.finish!
    tree.choice_tape = tape
    tree
  end

  private def inc_shrink_step
    @shrink_steps += 1
    @io.print '.' if @config.verbose
  end

  private def print_shrinking_exceeded_message
    @io.puts "(Note: Exceeded #{@config.max_shrink_steps} shrinking steps, the maximum.)"
  end
end
