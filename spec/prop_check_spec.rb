require 'thread'

RSpec.describe PropCheck do
  it 'has a version number' do
    expect(PropCheck::VERSION).not_to be nil
  end

  describe PropCheck do
    describe '.forall' do
      it 'returns a Property when called without a block' do
        expect(PropCheck.forall(x: PropCheck::Generators.integer)).to be_a(PropCheck::Property)
      end

      it 'runs the property test when called with a block' do
        expect { |block| PropCheck.forall(x: PropCheck::Generators.integer, &block) }.to yield_control
      end

      it 'accepts simple arguments' do
        expect do
          PropCheck.forall(PropCheck::Generators.integer, PropCheck::Generators.float) do |x, y|
            expect(x).to be_a Integer
            expect(y).to be_a Float
          end
        end.not_to raise_error
      end

      it 'accepts keyword arguments' do
        expect do
          PropCheck.forall(x: PropCheck::Generators.integer, y: PropCheck::Generators.float) do |x:, y:|
            expect(x).to be_a Integer
            expect(y).to be_a Float
          end
        end.not_to raise_error
      end

      it 'raises when receiving both simple and keyword arguments at the same time' do
        expect do
          PropCheck.forall(PropCheck::Generators.integer, a: PropCheck::Generators.integer) do |int, hash|
            expect(int).to be_a Integer
            expect(hash[:x]).to be_a Float
          end
        end.to raise_error(ArgumentError)
      end

      it 'will not shrink upon encountering a SystemExit' do
        expect do
          PropCheck.forall(x: PropCheck::Generators.integer) do |x:|
            raise SystemExit if x > 3
          end
        end.to raise_error do |error|
          expect(error).to be_a(SystemExit)

          # Check for no shrinking:
          expect(defined?(error.prop_check_info)).to be_nil
        end
      end

      it 'will not shrink upon encountering a SignalException' do
        expect do
          PropCheck.forall(x: PropCheck::Generators.integer) do |x:|
            Process.kill('HUP', Process.pid) if x > 3
          end
        end.to raise_error do |error|
          expect(error).to be_a(SignalException)

          # Check for no shrinking:
          expect(defined?(error.prop_check_info)).to be_nil
        end
      end

      it 'passes SystemExit through without shrinking when using workers' do
        expect do
          PropCheck.forall(x: PropCheck::Generators.integer)
                   .with_config(workers: 4, seed: 12_345, n_runs: 20)
                   .check { |x:| raise SystemExit if x > 3 }
        end.to raise_error(SystemExit) do |error|
          expect(defined?(error.prop_check_info)).to be_nil
        end
      end

      it 'shrinks and returns an exception with the #prop_check_info method upon finding a failure case' do
        class MyCustomError < StandardError; end
        expected_keys = %i[original_input original_exception_message shrunken_input shrunken_exception
                           n_successful n_shrink_steps]
        exploding_val = nil
        shrunken_val = nil

        expect do
          PropCheck.forall(x: PropCheck::Generators.float) do |x:|
            if x > 3.1415
              exploding_val ||= x
              shrunken_val = x
              raise MyCustomError, 'I do not like this number'
            end
          end
        end.to raise_error do |error|
          expect(error).to be_a(MyCustomError)
          expect(defined?(error.prop_check_info)).to eq('method')
          info = error.prop_check_info
          expect(info.keys).to contain_exactly(*expected_keys)

          expect(info[:original_exception_message]).to eq('I do not like this number')
          expect(info[:original_input]).to eq({ x: exploding_val })
          expect(info[:shrunken_input]).to eq({ x: shrunken_val })
          expect(info[:n_successful]).to be_a(Integer)
          expect(info[:n_shrink_steps]).to be_a(Integer)
        end
      end
    end

    describe 'Property' do
      describe '#with_config' do
        it 'updates the configuration' do
          p = PropCheck.forall(x: PropCheck::Generators.integer)
          expect(p.configuration[:verbose]).to be false
          expect(p.with_config(verbose: true).configuration[:verbose]).to be true
        end
        it 'Runs the property test when called with a block' do
          expect do |block|
            PropCheck.forall(x: PropCheck::Generators.integer).with_config(**{}, &block)
          end.to yield_control
        end
      end

      describe '#check' do
        it 'generates an error that Rspec can pick up' do
          expect do
            PropCheck.forall(x: PropCheck::Generators.nonnegative_integer).with_config(n_runs: 1_000) do |x:|
              expect(x).to be < 10
            end
          end.to raise_error do |error|
            expect(error).to be_a(RSpec::Expectations::ExpectationNotMetError)
            expect(error.message).to match(/\(after \d+ successful property test runs\)/m)
            expect(error.message).to match(/Exception message:/m)

            # Test basic shrinking real quick:
            expect(error.message).to match(/Shrunken input \(after \d+ shrink steps\):/m)
            expect(error.message).to match(/Shrunken exception:/m)

            expect(defined?(error.prop_check_info)).to eq('method')
            # p error.prop_check_info
          end
        end

        it "generates an error with 'shrinking impossible' if the value cannot be shrunk further" do
          expect do
            PropCheck.forall(PropCheck::Generators.array(PropCheck::Generators.integer))
                     .with_config(seed: 1)
                     .check { |array| array.sum / array.length }
          end.to raise_error do |error|
            expect(error).to be_a(ZeroDivisionError)
            expect(error.message).to match(/\(shrinking impossible\)/)
          end
        end
      end

      describe 'parallel execution' do
        def indexed_random_generator
          PropCheck::Generator.new do |size:, rng:, **|
            PropCheck::LazyTree.new([size, rng.rand(-size..size)])
          end
        end

        it 'generates the same seeded sample sequence with one or four workers' do
          generator = indexed_random_generator

          collect_samples = lambda do |workers|
            samples = []
            mutex = Mutex.new

            PropCheck.forall(generator)
                     .with_config(n_runs: 20, workers: workers, seed: 12_345)
                     .check do |sample|
              mutex.synchronize { samples << sample }
            end

            samples.sort_by(&:first).map(&:last)
          end

          expect(collect_samples.call(4)).to eq(collect_samples.call(1))
        end

        it 'chooses the smallest-index failure when later samples finish first' do
          generator = PropCheck::Generator.new do |size:, **|
            PropCheck::LazyTree.wrap(size)
          end

          gates = Hash.new { |hash, key| hash[key] = Queue.new }
          started = Queue.new
          completion_order = []
          cleanups = []
          mutex = Mutex.new

          controller = Thread.new do
            3.times { started.pop }
            [4, 3, 2, 1].each { |sample| gates[sample] << :continue }
          end

          property =
            PropCheck.forall(generator)
                     .with_config(n_runs: 4, workers: 4, seed: 987)
                     .around do |&block|
              block.call
            ensure
              sample = Thread.current[:parallel_sample]
              mutex.synchronize { cleanups << sample } if sample
            end

          expect do
            property.check do |sample|
              Thread.current[:parallel_sample] = sample

              if sample == 1
                gates[sample].pop
              else
                started << sample
                gates[sample].pop
              end

              mutex.synchronize { completion_order << sample }
              raise "failure #{sample}" unless sample == 1
            end
          end.to raise_error do |error|
            expect(error.prop_check_info[:original_input]).to eq(2)
            expect(error.prop_check_info[:n_successful]).to eq(1)
          end

          controller.join
          mutex.synchronize do
            expect(completion_order).to eq([4, 3, 2, 1])
            expect(cleanups.sort).to eq([1, 2, 3, 4])
          end
        end

        it 'keeps generated and in-flight samples bounded by the worker count' do
          generator = PropCheck::Generator.new do |size:, **|
            PropCheck::LazyTree.wrap(size)
          end

          gates = Hash.new { |hash, key| hash[key] = Queue.new }
          started = Queue.new
          mutex = Mutex.new
          active = 0
          max_active = 0
          generated = 0
          after_calls = 0
          controller_error = nil
          first_samples = nil

          controller = Thread.new do
            begin
              first_samples = 4.times.map { started.pop }.sort
              [4, 1, 5, 2, 6, 3, 7, 8].each { |sample| gates[sample] << :continue }
            rescue => error
              controller_error = error
            end
          end

          property =
            PropCheck.forall(generator)
                   .with_config(n_runs: 8, workers: 4, seed: 555)
                   .after { mutex.synchronize { after_calls += 1 } }
                   .around do |&block|
              mutex.synchronize do
                active += 1
                max_active = [max_active, active].max
              end
              block.call
            ensure
              mutex.synchronize { active -= 1 }
            end
          property.check do |sample|
            started << sample
            gates[sample].pop

            mutex.synchronize do
              generated += 1
            end
          end

          controller.join
          raise controller_error if controller_error

          mutex.synchronize do
            expect(first_samples).to eq([1, 2, 3, 4])
            expect(generated).to eq(8)
            expect(max_active).to eq(4)
            expect(after_calls).to eq(8)
          end
        end
      end

      describe '#where' do
        it 'filters results' do
          PropCheck.forall(x: PropCheck::Generators.integer,
                           y: PropCheck::Generators.positive_integer).where do |x:, y:|
            x != y
          end.check do |x:, y:|
            expect(x).to_not eq y
          end
        end

        it 'raises an error if too much was filtered' do
          expect do
            PropCheck.forall(x: PropCheck::Generators.positive_integer).where { |x:| x == 0 }.check do
            end
          end.to raise_error do |error|
            expect(error).to be_a(PropCheck::Errors::GeneratorExhaustedError)
            # Check for no shrinking:
            expect(defined?(error.prop_check_info)).to be_nil
          end
        end

        it 'crashes when doing nonesense in the where block' do
          expect do
            PropCheck.forall(x: PropCheck::Generators.negative_integer).where { |x:| x.unexistentmethod == 3 }.check do
            end
          end.to raise_error do |error|
            expect(error).to be_a(NoMethodError)
            # Check for no shrinking:
            expect(defined?(error.prop_check_info)).to be_nil
          end
        end
      end

      describe '.configure' do
        it 'configures all checks done from that point onward' do
          PropCheck::Property.configure do |config|
            config.n_runs = 42
          end

          expect(PropCheck.forall(foo: PropCheck::Generators.integer).configuration.n_runs).to be 42
        end
      end
      describe 'hooks' do
        describe '#before' do
          it 'calls the before block before every generated value (even filtered ones)' do
            expect do |before_hook|
              PropCheck.forall(PropCheck::Generators.integer)
                       .with_config(n_runs: 100)
                       .before(&before_hook)
                       .where { |x| x.odd? }
                       .check do
              end
            end.to yield_control.exactly(100).times
          end
        end

        describe '#after' do
          it 'calls the after block after every generated value (even filtered ones)' do
            expect do |after_hook|
              PropCheck.forall(PropCheck::Generators.integer)
                       .with_config(n_runs: 100)
                       .after(&after_hook)
                       .where { |x| x.even? }
                       .check do
              end
            end.to yield_control.exactly(100).times
          end
        end

        describe '#around' do
          it 'calls the around block around every generated value (even filtered ones)' do
            before_calls = 0
            after_calls = 0
            inner_calls = 0
            around_hook = proc do |&block|
              before_calls += 1
              block.call
            ensure
              after_calls += 1
            end
            PropCheck.forall(PropCheck::Generators.integer)
                     .with_config(n_runs: 100)
                     .around(&around_hook)
                     .where { |x| x.odd? }
                     .check do
              inner_calls += 1
            end
            expect(before_calls).to eq(100)
            expect(after_calls).to eq(100)
            expect(inner_calls).to eq(100)
          end
        end
      end
    end

    describe 'including PropCheck in a testing-environment' do
      include PropCheck
      include PropCheck::Generators
      it 'adds forall to the example scope and brings generators inside PropCheck::Generators into scope`' do
        thing = nil
        forall(x: integer) do |x:|
          expect(x).to be_a(Integer)
          thing = true
        end
        expect(thing).to be true
      end
    end

    describe 'generating a hash' do
      include PropCheck::Generators

      it 'does not fail when calling call_splatted with non-symbol keys' do
        PropCheck.forall(hash_of(integer, integer)) do |h|
          expect(h).to be_a(Hash)
        end
      end
    end

    describe 'resizing' do
      include PropCheck::Generators

      it 'will not find a counter-example if resized to logarithmically while iterating only 100 times' do
        PropCheck.forall(integer).growing_logarithmically do |val|
          expect(val).to be < 6
        end
      end
    end
  end
end
