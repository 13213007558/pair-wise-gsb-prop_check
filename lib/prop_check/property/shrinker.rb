require 'prop_check/helper'
require 'set'

class PropCheck::Property::Shrinker
  class MinHeap
    def initialize
      @items = []
      @insertion_count = 0
    end

    def empty?
      @items.empty?
    end

    def any?
      !empty?
    end

    def push(priority, item)
      @items << [priority, @insertion_count, item]
      @insertion_count += 1
      bubble_up(@items.length - 1)
    end

    def pop
      return if empty?

      item, last = @items.values_at(0, -1)
      @items.pop
      unless @items.empty?
        @items[0] = last
        bubble_down(0)
      end
      item.last
    end

    private

    def bubble_up(index)
      item = @items[index]

      while index.positive?
        parent_index = (index - 1) / 2
        parent = @items[parent_index]
        break if heap_less?(parent, item)

        @items[index] = parent
        index = parent_index
      end

      @items[index] = item
    end

    def bubble_down(index)
      item = @items[index]
      loop do
        smallest = index
        left = (index * 2) + 1
        right = left + 1

        smallest = left if left < @items.length && heap_less?(@items[left], item)
        smallest = right if right < @items.length && heap_less?(@items[right], @items[smallest])
        break if smallest == index

        @items[index] = @items[smallest]
        index = smallest
      end

      @items[index] = item
    end

    def heap_less?(first, second)
      first[0] < second[0] || (first[0] == second[0] && first[1] < second[1])
    end
  end

  def initialize(bindings_tree, io, hooks, config, problem_exception)
    @problem_child = bindings_tree
    @io = io
    @problem_exception = problem_exception
    @hooks = hooks
    @config = config
    @failure_category = classify(problem_exception, @problem_child.root)
    @shrink_steps = 0
    @candidate_count = 0
    @checked_candidates = Set.new([candidate_key(@problem_child.root)])
    @stopped = :complete
    @sources = [lazy_children(@problem_child)]
    @pending = MinHeap.new if @config.complexity_function
  end

  def self.call(bindings_tree, io, hooks, config, problem_exception, &block)
    self
      .new(bindings_tree, io, hooks, config, problem_exception)
      .call(&block)
  end

  def call(&block)
    @io.puts 'Shrinking...' if @config.verbose

    shrink(&block)
    @stopped = :candidate_budget_exhausted if candidate_budget_reached_with_pending_sources?
    @stopped = :property_budget_exhausted if @shrink_steps >= @config.max_shrink_steps

    [@problem_child.root, @problem_exception, @shrink_steps, @stopped]
  end

  private def shrink(&block)
    while (sibling = next_candidate)
      break if @shrink_steps >= @config.max_shrink_steps

      run_candidate(sibling, &block)
      break if @shrink_steps >= @config.max_shrink_steps
    end
  end

  private def next_candidate
    if @config.complexity_function
      refill_pending while @pending.empty? && !@sources.empty? && candidates_remaining?
      unless @pending.empty?
        @pending.pop
      end
    else
      next_depth_first_candidate
    end
  end

  private def refill_pending
    while (source = @sources.shift)
      status, candidate = read_candidate(source)
      @sources << source unless status == :exhausted
      add_candidate(candidate) if status == :candidate
      break if @candidate_count >= @config.max_shrink_candidates
    end
  end

  private def next_depth_first_candidate
    while (source = @sources.first)
      status, candidate = read_candidate(source)
      if status == :candidate
        return candidate
      else
        @sources.shift if status == :exhausted
        return nil unless status == :duplicate
      end
    end

    nil
  end

  private def read_candidate(source)
    return [:budget_exhausted] unless candidates_remaining?

    sibling = source.next
    @candidate_count += 1
    key = candidate_key(sibling.root)
    return [:duplicate] if @checked_candidates.include?(key)

    @checked_candidates << key
    [:candidate, sibling]
  rescue StopIteration
    [:exhausted]
  end

  private def add_candidate(sibling)
    @pending.push(complexity(sibling.root), sibling)
  end

  private def add_children(sibling)
    source = lazy_children(sibling)
    unless @config.complexity_function
      @sources.unshift(source)
      return
    end

    loop do
      status, candidate = read_candidate(source)
      if status == :exhausted
        return
      elsif status == :candidate
        add_candidate(candidate)
        @sources.unshift(source)
        return
      elsif status == :budget_exhausted
        @sources.unshift(source)
        return
      end
    end
  end

  private def lazy_children(sibling)
    children = sibling.children
    children.is_a?(Enumerator::Lazy) ? children : children.lazy
  end

  private def candidates_remaining?
    if @candidate_count >= @config.max_shrink_candidates
      @stopped = :candidate_budget_exhausted
      false
    else
      true
    end
  end

  private def candidate_budget_reached_with_pending_sources?
    @candidate_count >= @config.max_shrink_candidates && (@sources.any? || !@pending.nil? && @pending.any?)
  end

  private def run_candidate(sibling, &block)
    @shrink_steps += 1
    @io.print '.' if @config.verbose

    begin
      PropCheck::Helper.call_splatted(sibling.root, &block)
    rescue SignalException, SystemExit
      raise
    rescue Exception => e
      same_failure_category = classify(e, sibling.root) == @failure_category
      add_children(sibling)
      return unless same_failure_category
      return if @config.complexity_function && complexity(sibling.root) >= complexity(@problem_child.root)

      @problem_child = sibling
      @problem_exception = e
    end
  ensure
    @stopped = :property_budget_exhausted if @shrink_steps >= @config.max_shrink_steps
  end

  private def classify(exception, value)
    call_with_value(@config.failure_classifier, exception, value)
  end

  private def complexity(value)
    call_proc(@config.complexity_function, value)
  end

  private def candidate_key(value)
    return call_proc(@config.candidate_key_function, value) if @config.candidate_key_function

    [:prop_check_candidate, value.class, value.object_id]
  end

  private def call_with_value(callable, exception, value)
    arity = callable.arity
    return callable.call if arity.zero?
    return callable.call(exception, value) if arity.negative? || arity >= 2

    callable.call(exception)
  end

  private def call_proc(callable, value)
    return nil unless callable

    arity = callable.arity
    return callable.call if arity.zero?
    callable.call(value)
  end
end
