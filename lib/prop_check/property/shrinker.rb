require 'prop_check/helper'

class PropCheck::Property::Shrinker
  SEEN = Object.new.freeze
  private_constant :SEEN

  class MinHeap
    def initialize
      @entries = []
      @sequence = 0
    end

    def push(item, priority)
      @entries << [item, priority, @sequence]
      @sequence += 1
      bubble_up(@entries.length - 1)
    end

    def pop
      return if empty?

      swap(0, @entries.length - 1)
      item = @entries.pop.first
      bubble_down(0)
      item
    end

    def empty?
      @entries.empty?
    end

    private

    def bubble_up(index)
      while index > 0
        parent = (index - 1) / 2
        break unless before?(index, parent)

        swap(index, parent)
        index = parent
      end
    end

    def bubble_down(index)
      loop do
        smallest = index
        left = (index * 2) + 1
        right = left + 1

        smallest = left if left < @entries.length && before?(left, smallest)
        smallest = right if right < @entries.length && before?(right, smallest)
        break if smallest == index

        swap(index, smallest)
        index = smallest
      end
    end

    def before?(left, right)
      comparison = @entries[left][1] <=> @entries[right][1]
      raise ArgumentError, 'complexity_function must return comparable values' if comparison.nil?

      comparison.negative? || (comparison.zero? && @entries[left][2] < @entries[right][2])
    end

    def swap(left, right)
      @entries[left], @entries[right] = @entries[right], @entries[left]
    end
  end

  private_constant :MinHeap

  def initialize(bindings_tree, io, hooks, config, original_exception)
    @problem_child = bindings_tree
    @io = io
    @hooks = hooks
    @config = config
    @problem_exception = original_exception
    @original_failure_category = failure_category(original_exception, @problem_child.root)
    @shrink_steps = 0
    @candidate_count = 0
    @candidate_budget_exhausted = false
    @evaluated = {}
    @expanded = {}
    mark_evaluated!(@problem_child)
  end

  def self.call(bindings_tree, io, hooks, config, original_exception, &block)
    new(bindings_tree, io, hooks, config, original_exception).call(&block)
  end

  def call(&block)
    @io.puts 'Shrinking...' if @config.verbose

    search(&block)

    [@problem_child.root, @problem_exception, @shrink_steps, status]
  end

  private

  def search(&block)
    if @config.complexity_function.nil?
      depth_first_search(&block)
    else
      complexity_first_search(&block)
    end
  end

  def depth_first_search(&block)
    frontier = [children_enum(@problem_child)]

    while execution_budget_remaining? && !candidate_budget_reached?
      candidate = next_depth_first_candidate(frontier)
      break if candidate.nil?

      if evaluated?(candidate)
        next if expanded?(candidate)
        expand_candidate(frontier, candidate)
      else
        mark_evaluated!(candidate)
        result = evaluate_candidate(candidate, &block)
        next if result == :success

        descend_after_failure(frontier, candidate)
      end
    end

    @candidate_budget_exhausted ||= candidate_budget_reached? && !frontier.empty?
  end

  def next_depth_first_candidate(frontier)
    until frontier.empty?
      candidate =
        begin
          frontier.last.next
        rescue StopIteration
          frontier.pop
          next
        end

      @candidate_count += 1
      return candidate
    end
  end

  def complexity_first_search(&block)
    frontier = MinHeap.new
    enqueue_children(@problem_child, frontier) if execution_budget_remaining?

    while execution_budget_remaining?
      candidate_item = frontier.pop
      break if candidate_item.nil?

      mode, candidate = candidate_item
      if mode == :expand
        mark_expanded!(candidate)
        enqueue_children(candidate, frontier)
      else
        mark_evaluated!(candidate)
        result = evaluate_candidate(candidate, &block)
        next if result == :success

        mark_expanded!(candidate)
        enqueue_children(candidate, frontier)
      end
    end
  end

  def enqueue_children(parent, frontier)
    children = children_enum(parent)

    loop do
      if candidate_budget_reached?
        @candidate_budget_exhausted = true
        break
      end

      candidate =
        begin
          children.next
        rescue StopIteration
          break
        end

      @candidate_count += 1
      mode = evaluated?(candidate) ? (expanded?(candidate) ? nil : :expand) : :evaluate
      frontier.push([mode, candidate], complexity(candidate.root)) unless mode.nil?
    end
  end

  def expand_candidate(frontier, candidate)
    descend_after_failure(frontier, candidate)
  end

  def descend_after_failure(frontier, candidate)
    mark_expanded!(candidate)
    current_enum = frontier.pop
    frontier.unshift(current_enum)
    frontier.unshift(children_enum(candidate))
  end

  def evaluate_candidate(candidate, &block)
    @shrink_steps += 1
    @io.print '.' if @config.verbose

    begin
      @hooks.call do
        PropCheck::Helper.call_splatted(candidate.root, &block)
      end
      :success
    # It is correct that we want to rescue _all_ Exceptions
    # not only 'StandardError's
    rescue Exception => exception
      if failure_category(exception, candidate.root) == @original_failure_category
        @problem_child = candidate
        @problem_exception = exception
        :matching_failure
      else
        :different_failure
      end
    end
  end

  def children_enum(tree)
    tree.children.lazy
  end

  def execution_budget_remaining?
    @shrink_steps < @config.max_shrink_steps
  end

  def candidate_budget_reached?
    @candidate_count >= @config.max_shrink_candidates
  end

  def evaluated?(candidate)
    present?(@evaluated, candidate.root)
  end

  def expanded?(candidate)
    present?(@expanded, candidate.root)
  end

  def mark_evaluated!(candidate)
    mark_present!(@evaluated, candidate.root)
  end

  def mark_expanded!(candidate)
    mark_present!(@expanded, candidate.root)
  end

  def present?(store, value)
    bucket, key = identity(store, value)
    bucket[key].equal?(SEEN)
  end

  def mark_present!(store, value)
    bucket, key = identity(store, value)
    bucket[key] = SEEN
  end

  def identity(store, value)
    return [store, [:value, value]] if @config.candidate_key_function.nil?

    [store, [:key, candidate_key(value)]]
  end

  def candidate_key(value)
    return value if @config.candidate_key_function.nil?

    @config.candidate_key_function.call(value)
  end

  def complexity(value)
    @config.complexity_function.call(value)
  end

  def failure_category(exception, value)
    return :any_failure if @config.failure_classifier.nil?

    @config.failure_classifier.call(exception, value)
  end

  def execution_budget_exhausted?
    @shrink_steps >= @config.max_shrink_steps
  end

  def status
    {
      complete: !@candidate_budget_exhausted && !execution_budget_exhausted?,
      candidates_generated: @candidate_count,
      candidates_checked: @shrink_steps,
      candidate_budget_exhausted: @candidate_budget_exhausted,
      execution_budget_exhausted: execution_budget_exhausted?
    }
  end
end
