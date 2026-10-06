RSpec.describe 'Parallel property checking (n_workers > 1)' do
  # A controllable barrier, used to deterministically orchestrate
  # the order in which parallel checks complete,
  # without relying on the global random state or on `sleep`.
  class ControlledBarrier
    def initialize
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @released = {}
      @arrivals = Queue.new
    end

    # Blocks the current thread until `release` is called with `token`.
    # Records the arrival so the test can observe it.
    def await(token)
      @arrivals << token
      @mutex.synchronize do
        @condition.wait(@mutex) until @released[token]
      end
    end

    def release(token)
      @mutex.synchronize do
        @released[token] = true
        @condition.broadcast
      end
    end

    # Waits for the next token that arrived at the barrier.
    def next_arrival
      @arrivals.pop
    end

    # Returns the next arrived token if one is available, else nil.
    def try_arrival
      @arrivals.pop(true)
    rescue ThreadError
      nil
    end
  end

  # Thread-safe counter for checking hook invocations.
  class HookCounter
    def initialize
      @mutex = Mutex.new
      @counts = Hash.new(0)
    end

    def increment(key)
      @mutex.synchronize { @counts[key] += 1 }
    end

    def [](key)
      @mutex.synchronize { @counts[key] }
    end
  end

  let(:seed) { 12_345 }
  # Resize the generators so generated values are (practically) unique,
  # which lets the barrier address every sample individually.
  let(:resize) { proc { |size| size * 1_000_000 } }

  # Runs the property in a background thread,
  # returning the thread whose #value is nil on success
  # or the raised exception on failure.
  def run_in_background(property, &block)
    Thread.new do
      begin
        property.check(&block)
        nil
      rescue Exception => e
        e
      end
    end
  end

  def samples_with(n_workers, n_runs:, resize: nil)
    seen = []
    lock = Mutex.new
    config = { n_runs: n_runs, n_workers: n_workers, seed: seed }
    config[:resize_function] = resize if resize
    PropCheck.forall(x: PropCheck::Generators.integer)
             .with_config(**config)
             .check { |x:| lock.synchronize { seen << x } }
    seen
  end

  it 'defaults to a single worker' do
    expect(PropCheck::Property::Configuration.new.n_workers).to eq(1)
    expect(PropCheck::Property::Configuration.new.seed).to be_nil
  end

  it 'generates the same logical sequence of samples for any worker count' do
    sequential = samples_with(1, n_runs: 50)
    parallel = samples_with(4, n_runs: 50)
    parallel_again = samples_with(4, n_runs: 50)

    expect(parallel).to match_array(sequential)
    expect(parallel_again).to match_array(sequential)
    expect(samples_with(1, n_runs: 50)).to eq(sequential)
  end

  it 'reports the earliest failing sample as the counterexample, even when a later sample fails first' do
    n_runs = 20
    values = samples_with(1, n_runs: n_runs, resize: resize)
    expect(values.uniq.size).to eq(n_runs)

    failing = { values[1] => true, values[3] => true }
    barrier = ControlledBarrier.new
    hooks = HookCounter.new

    property = PropCheck.forall(x: PropCheck::Generators.integer)
                        .with_config(n_runs: n_runs, n_workers: 4, seed: seed, resize_function: resize)
                        .before { hooks.increment(:before) }
                        .after { hooks.increment(:after) }

    runner = run_in_background(property) do |x:|
      barrier.await(x) if values.include?(x)
      raise "boom for #{x}" if failing[x]
    end

    # The first batch of attempts (one per worker) starts.
    first_batch = Array.new(4) { barrier.next_arrival }
    expect(first_batch.sort).to eq(values[0..3].sort)

    # Deliberately invert the completion order:
    # the later sample (index 3) fails first...
    barrier.release(values[3])
    # ...then the earliest sample passes...
    barrier.release(values[0])
    # ...and only then the earlier failure (index 1) completes,
    # which determines the final outcome.
    barrier.release(values[1])

    # Release everything so in-flight attempts can finish
    # and the workers can be joined. (Releasing is idempotent.)
    values.each { |value| barrier.release(value) }

    error = runner.value
    expect(error).to be_a(RuntimeError)

    # The counterexample is the failure with the lowest index,
    # not the failure that completed first.
    info = error.prop_check_info
    expect(info[:original_input]).to eq(x: values[1])
    expect(info[:n_successful]).to eq(1)

    # No more samples were started once the outcome was decided:
    # not all inputs were generated.
    arrivals = []
    while (value = barrier.try_arrival)
      arrivals << value
    end
    expect(first_batch.size + arrivals.size).to be < n_runs

    # after-hooks were not skipped, even for the failing attempts.
    expect(hooks[:before]).to eq(hooks[:after])
    expect(hooks[:before]).to be_positive

    # A sequential run with the same seed finds exactly the same
    # counterexample and shrinks it in exactly the same way.
    sequential_error =
      begin
        PropCheck.forall(x: PropCheck::Generators.integer)
                 .with_config(n_runs: n_runs, n_workers: 1, seed: seed, resize_function: resize)
                 .check { |x:| raise "boom for #{x}" if failing[x] }
        nil
      rescue Exception => e
        e
      end
    sequential_info = sequential_error.prop_check_info
    expect(info[:original_input]).to eq(sequential_info[:original_input])
    expect(info[:shrunken_input]).to eq(sequential_info[:shrunken_input])
    expect(info[:n_shrink_steps]).to eq(sequential_info[:n_shrink_steps])
  end

  it 'bounds in-flight work and runs the hooks exactly once per sample' do
    n_runs = 20
    generated_sizes = []
    generation_lock = Mutex.new
    recording_generator = PropCheck::Generator.new do |size:, rng:, **kwargs|
      generation_lock.synchronize { generated_sizes << size }
      PropCheck::Generators.integer.generate(size: size, rng: rng, **kwargs)
    end

    barrier = ControlledBarrier.new
    hooks = HookCounter.new

    property = PropCheck.forall(x: recording_generator)
                        .with_config(n_runs: n_runs, n_workers: 4, seed: seed, resize_function: resize)
                        .before { hooks.increment(:before) }
                        .after { hooks.increment(:after) }
                        .around { |&block| hooks.increment(:around); block.call }

    runner = run_in_background(property) { |x:| barrier.await(x) }

    # Only one attempt per worker is in flight;
    # no further inputs are generated while they are blocked.
    arrived = Array.new(4) { barrier.next_arrival }
    expect(barrier.try_arrival).to be_nil
    expect(generated_sizes.sort).to eq([1, 2, 3, 4].map { |i| i * 1_000_000 })

    # Releasing one sample lets exactly one new attempt start.
    barrier.release(arrived.first)
    arrived << barrier.next_arrival
    expect(barrier.try_arrival).to be_nil
    expect(generated_sizes.sort).to eq([1, 2, 3, 4, 5].map { |i| i * 1_000_000 })

    # Drive the run to completion.
    arrived.each { |value| barrier.release(value) }
    while arrived.size < n_runs
      arrived << barrier.next_arrival
      barrier.release(arrived.last)
    end

    expect(runner.value).to be_nil
    expect(generated_sizes.sort).to eq((1..n_runs).map { |i| i * 1_000_000 })
    expect(hooks[:before]).to eq(n_runs)
    expect(hooks[:after]).to eq(n_runs)
    expect(hooks[:around]).to eq(n_runs)
  end

  it 'propagates generator exhaustion like a sequential run' do
    expect do
      PropCheck.forall(PropCheck::Generators.integer)
               .where { |x| x > 1_000_000 }
               .with_config(n_runs: 5, n_workers: 4, seed: seed, max_consecutive_attempts: 3)
               .check { |x| x }
    end.to raise_error(PropCheck::Errors::GeneratorExhaustedError)
  end

  it 'does not shrink (and reraises) when the check is interrupted' do
    error =
      begin
        PropCheck.forall(x: PropCheck::Generators.integer)
                 .with_config(n_runs: 10, n_workers: 4, seed: seed)
                 .check { |x:| raise SystemExit if x > 1 }
        nil
      rescue Exception => e
        e
      end

    expect(error).to be_a(SystemExit)
    expect(defined?(error.prop_check_info)).to be_nil
  end
end
